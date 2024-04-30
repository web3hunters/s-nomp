#!/bin/bash
##
## © verus.io 2018-2024, released under MIT license
## Script written in 2023 by Oink.vrsc@
## Script maintained by Oink.vrsc@

# check if script is already running
if [ -f /tmp/pbaascheck.pid ]
then
  PID_TIME=$(stat -c '%W' /tmp/pbaascheck.pid)
  CUR_TIME=$(date +%s)
  PID_AGE=$(echo "$CUR_TIME - $PID_TIME" | bc)
  if [[ $PID_AGE <= 3600 ]]
  then
    echo "script is already running"
    exit 1
  else
    echo "script has apparently aborted before removing /tmp/pbaascheck.pid, continuing"
  fi
else
  touch /tmp/pbaascheck.pid
fi

## default settings (change where needed)
PAYMENT=/home/pool/payment       # Change if you used a different location
VERUS=/home/verus/bin/verus      # complete path to (and including) the verus RPC client
MAIN_CHAIN=VRSC                  # main hashing chain
REDIS_NAME=verus                 # name you assigned the coin in `/home/pool/s-nomp/coins/*.json`
REDIS_HOST=127.0.0.1             # If you run this script on another system, alter the IP address of your Redis server
REDIS_PORT=6379                  # If you use a different REDIS port, alter the port accordingly

## Set script folder
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

## check if the Verus binary is found.
## If Verus exists in the PATH environment, use it.
## If not, fall back to predefined location in this script.
if ! command -v verus &>/dev/null
then
  echo "verus not found in your PATH environment. Using location from line 9 in this script."
  if ! command -v $VERUS &>/dev/null
  then
    echo "Verus could not be found. Make sure it's in your path and/or in line 9 of this script."
    echo "exiting..."
    exit 1
  fi
else
  VERUS=$(which verus)
fi


## Dependencies: bc, jq, tr, cut, redis-cli/keydb-cli
## bc
if ! command -v bc &>/dev/null ; then
    echo "jq not found. please install using your package manager."
    exit 1
else
    BC=$(which bc)
fi
## jq
if ! command -v jq &>/dev/null ; then
    echo "jq not found. please install using your package manager."
    exit 1
else
    JQ=$(which jq)
fi
## tr
if ! command -v tr &>/dev/null ; then
    echo "tr not found. please install using your package manager."
    exit 1
else
    TR=$(which tr)
fi
## cut
if ! command -v cut &>/dev/null ; then
    echo "cut not found. please install using your package manager."
    exit 1
else
    CUT=$(which cut)
fi
## redis-cli and/or keydb-cli
if ! command -v redis-cli &>/dev/null ; then
    if ! command -v keydb-cli &>/dev/null ; then
       echo "Both redis-cli or keydb-cli not found. Please install one using your package manager."
       exit 1
    fi
    REDIS_CLI="$(which keydb-cli) -h $REDIS_HOST -p $REDIS_PORT"
else
    REDIS_CLI="$(which redis-cli) -h $REDIS_HOST -p $REDIS_PORT"
fi

## Can we connect to Redis?
if [[ "$($REDIS_CLI ping)" != "PONG" ]]
then
  echo "cannot connect to redis server"
  exit 1
fi

## Is main chain active?
count=$(${VERUS} -chain=$MAIN_CHAIN getconnectioncount 2>/dev/null)
case $count in
  ''|*[!0-9]*) DAEMON_ACTIVE=0 ;;
  *) DAEMON_ACTIVE=1 ;;
esac
if [[ "$DAEMON_ACTIVE" != "1" ]]
then
  echo "$MAIN_CHAIN daemon is not running and connected. Start your $MAIN_CHAIN daemon and wait for it to be connected."
  exit 1
fi

## Return a list of found PBaaS hashes:
HASHLIST=$($REDIS_CLI smembers $REDIS_NAME:pbaasPending | $CUT -d' ' -f2-)
## return a list on found shares per miner
SHARELIST=$($REDIS_CLI hgetall $REDIS_NAME:shares:roundCurrent| $CUT -d' ' -f2-)
## get list of active chains in ecosystem
PBAAS_CHAINS=$($VERUS -chain=$MAIN_CHAIN listcurrencies '{"systemtype":"pbaas"}' | jq --arg MAIN_CHAIN "${MAIN_CHAIN}" -r '.[].currencydefinition | select (.name != "$MAIN_CHAIN") | .name')
## determine chains active on this system
for i in $PBAAS_CHAINS
do
  count=$(${VERUS} -chain=$i getconnectioncount 2>/dev/null)
  case $count in
    ''|*[!0-9]*) DAEMON_ACTIVE=0 ;;
    *) DAEMON_ACTIVE=1 ;;
  esac
  if [[ "$DAEMON_ACTIVE" = "1" ]]
  then
    ACTIVE_CHAINS="$ACTIVE_CHAINS $i"
  fi
done
ACTIVE_CHAINS=$(echo $ACTIVE_CHAINS | sed 's/VRSC//g');

## copy shares
for j in $ACTIVE_CHAINS
do
  # Do not insert data for the main mining chain
  if [[ "$(echo $j | $TR '[:upper:]' '[:lower:]')" != "$(echo $MAIN_CHAIN | $TR '[:upper:]' '[:lower:]')" ]]
  then
    $REDIS_CLI hset $(echo $j | $TR '[:upper:]' '[:lower:]'):shares:roundCurrent $SHARELIST 1>/dev/null
  fi
done

## Check each hash on all chains
for i in $HASHLIST
do
  for j in $ACTIVE_CHAINS
  ## put in break for non-running chains
  do
    CHECK=$($VERUS -chain=$j getblock $(echo $i | $CUT -d':' -f1) 2 2>/dev/null)
    if [[ "$CHECK" =~ "$(echo $i | cut -d':' -f1)"  ]]
    then
      TRANSACTION=$(echo "$CHECK" | $JQ -r '.tx[0].txid')
      BLOCK=$(echo "$CHECK" | $JQ  '.height')
      echo "$j contains blockhash $(echo $i | cut -d':' -f1), TXID: $TRANSACTION"
      REDIS_NEW_PENDING="${i:0:65}"$TRANSACTION:$BLOCK:"${i:65}"
      # do not insert data for the main mining chain
      if [[ "$(echo $j | $TR '[:upper:]' '[:lower:]')" != "$(echo $MAIN_CHAIN | $TR '[:upper:]' '[:lower:]')" ]]
      then
        $REDIS_CLI sadd $(echo $j | $TR '[:upper:]' '[:lower:]'):blocksPending $REDIS_NEW_PENDING 1>/dev/null
        ## if no shares are known for this round yet, add them
        SHARES_AVAILABLE="$($REDIS_CLI hgetall $(echo $j | tr '[:upper:]' '[:lower:]'):shares:round$BLOCK)"
        if [[ "$SHARES_AVAILABLE" == "" ]]
        then
          $REDIS_CLI hset $(echo $j | tr '[:upper:]' '[:lower:]'):shares:round$BLOCK $SHARELIST 1>/dev/null
        fi
      fi
    fi
  done
done

# Temporarily store unknown blockhashes in the script folder
# ToDo: Needs storing to Redis
UNKNOWN_HASHLIST=$($REDIS_CLI smembers $REDIS_NAME:pbaasPending | $CUT -d' ' -f2-)
if [ -f $SCRIPT_DIR/unknown_hashlist.4 ]
then
  while read -r LINE
  do
    if [[ "$UNKNOWN_HASHLIST" == *"$LINE"* ]]
    then
      echo "removing $LINE from REDIS"
      $REDIS_CLI srem $REDIS_NAME:pbaasPending $LINE 1>/dev/null
    fi
  done < $SCRIPT_DIR/unknown_hashlist.4
  rm $SCRIPT_DIR/unknown_hashlist.4
fi

for i in {3..1}
do
  if [ -f $SCRIPT_DIR/unknown_hashlist.$i ]
  then
    mv $SCRIPT_DIR/unknown_hashlist.$i $SCRIPT_DIR/unknown_hashlist.$((i+1))
  fi
done

for i in $UNKNOWN_HASHLIST
do
  echo $i >> $SCRIPT_DIR/unknown_hashlist.1
done

for CHAIN in $ACTIVE_CHAINS
do
  CHAINlc=$(echo $(echo $CHAIN | $TR '[:upper:]' '[:lower:]'))
  INVALIDADDRESS=$(cat $PAYMENT/pool_configs/$CHAINlc.json | jq -r .invalidAddress)
  echo "Processing i-addresses on $CHAIN. $INVALIDADDRESS used for nonexisting IDs"
  ALL_ADDRESSES=$($REDIS_CLI HSCAN $CHAINlc:balances 0 COUNT 50000 | awk '{print $1}' | sed -n 'n;p' | sed 's/\..*//' | grep -e "^i.*" | sort | uniq)
  while read -r ADDRESS; do
    if [[ $ADDRESS == i* ]]
    then
      I_ADDRESS=$ADDRESS
      BALANCES=
      DONATIONS=
      if [[ $($VERUS -chain=$CHAIN getidentity "$I_ADDRESS") ]]
      then
        echo "$I_ADDRESS exists on vARRR, no action needed."
      else
        ## Retrieve ID info from mainchain
        ID_MAINCHAIN=$($VERUS getidentity "$I_ADDRESS")
        # check if the ID exists on the main chain
        if [[ $(echo $IDMAINCHAIN) == error* ]]
        then
          break # testing WTF is happening.
          # Collect all address.worker entries for the i-address for move to donation address
          echo "$I_ADDRESS balance is a donation on $CHAIN..."
          DONATION_TMP=$($REDIS_CLI hscan $CHAINlc:balances 0 COUNT 40000 MATCH $ADDRESS* | awk 'NR % 2 == 0')
          if ! [ "$DONATION_TMP" == "" ]
          then
            DONATIONS=$DONATIONS$DONATION_TMP" "
            while read OLD_ADDRESS
            do
              BALANCE=0
              NEW_ADDRESS=0
              tmp=(${OLD_ADDRESS//./ })
              addr=${tmp[0]}
              NEW_ADDRESS=$(echo $OLD_ADDRESS | sed "s/${addr}/${INVALIDADDRESS}/g")
              BALANCE=$($REDIS_CLI HGET $CHAINlc:balances $OLD_ADDRESS)
              $REDIS_CLI HDEL $CHAINlc:balances $OLD_ADDRESS
              $REDIS_CLI HINCBYFLOAT $CHAINlc:balances $NEW_ADDRESS $BALANCE
            done <<<$DONATIONS
          fi
        else
          # Collect all address.worker entries for the i-address for move to R-address
          BALANCES_TMP=$($REDIS_CLI hscan $CHAINlc:balances 0 COUNT 40000 MATCH $ADDRESS* | awk 'NR % 2 == 0')
          if ! [ "$BALANCES_TMP" == "" ]
          then
            BALANCES=$BALANCES$BALANCES_TMP" "
            R_ADDRESS=$(echo $ID_MAINCHAIN | jq  -r .identity.primaryaddresses[0])
            while read OLD_ADDRESS
            do
              tmp=(${OLD_ADDRESS//./ })
              addr=${tmp[0]}
              NEW_ADDRESS=$(echo $OLD_ADDRESS | sed "s/${addr}/${R_ADDRESS}/g")
              BALANCE=$($REDIS_CLI HGET $CHAINlc:balances $OLD_ADDRESS)
              $REDIS_CLI HDEL $CHAINlc:balances $OLD_ADDRESS
              $REDIS_CLI HINCRBYFLOAT $CHAINlc:balances $NEW_ADDRESS $BALANCE
            done <<<$BALANCES
          fi
        fi
      fi
    fi
  done<<<$ALL_ADDRESSES
done

WORKERSHAREREDUCTION=
## Retrieve data from REDIS
WORKERSHARES=$($REDIS_CLI HGETALL $REDIS_NAME:shares:pbaasCurrent)

## if the value of shares is below two, remove the key from the database, otherwise substract 50% of the value
for LINE in $WORKERSHARES
do
  if [[ "$LINE" =~ ^[0-9] ]]
  then
    if [[ "$LINE" < "2.00000000" ]]
    then
      $REDIS_CLI HDEL $REDIS_NAME:shares:pbaasCurrent "$WORKERSHAREREDUCTION"
    else
      REDUCTION=$(echo "scale=8;$LINE / 2" | $BC)
      $REDIS_CLI HINCRBYFLOAT $REDIS_NAME:shares:pbaasCurrent "$WORKERSHAREREDUCTION" "-$REDUCTION"
    fi
    WORKERSHAREREDUCTION=
  else
    WORKERSHAREREDUCTION=$LINE
  fi
done <<<$WORKERSHARES

rm /tmp/pbaascheck.pid

#EOF
