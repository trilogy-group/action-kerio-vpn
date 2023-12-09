#!/usr/bin/env sh

VPN_CLIENT_VERSION=$1
VPN_USERNAME=$2
VPN_PASSWORD=$3
VPN_AUTH_CODE=$4
MAX_CURL_ATTEMPT=$5
MAX_SETUP_ATTEMPTS=$6
WAIT_KVN_TIMEOUT=$7

DESIRED_MTU=${5:-1500}  # Default to 1500 if not set
MINIMAL_MTU=1200  # Define a minimal MTU value
decrement_value=$(( (DESIRED_MTU - MINIMAL_MTU) / MAX_SETUP_ATTEMPTS ))  # Calculate decrement value

setMTU() {
    if [ $DESIRED_MTU -eq 1500 ]; then
        echo "MTU is at the default value of 1500, no change needed."
    elif [ $DESIRED_MTU -ge $MINIMAL_MTU ]; then
        echo "Setting MTU for kvnet to $DESIRED_MTU"
        sudo ip link set dev kvnet mtu $DESIRED_MTU
    else
        echo "MTU is already at or below minimal value of $MINIMAL_MTU"
    fi
}

waitForKvnet() {
    start_time=$(date +%s)
    while ! ip a show kvnet up | grep inet 2>/dev/null; do
        current_time=$(date +%s)
        elapsed_time=$(($current_time - $start_time))
        echo "Waiting for kvnet to start... Elapsed time: $elapsed_time seconds"
        if [ $elapsed_time -ge $WAIT_KVN_TIMEOUT ]; then
            echo "Error: kvnet did not start within $WAIT_KVN_TIMEOUT seconds"
            echo "Details of kvnet interface:"
            ip addr show kvnet
            return 1
        fi
        sleep 1
    done
    return 0
}

writeKerioConfigParam() {
  name=$1
  type=$2
  value=$3
  echo "kerio-control-vpnclient-${VPN_CLIENT_VERSION}-linux-amd64 kerio-kvc/$name $type $value" >> kerio.params
}

writeKerioConfig() {
  writeKerioConfigParam server string central-kerio-vpn.devfactory.com
  writeKerioConfigParam username string $VPN_USERNAME
  writeKerioConfigParam password string $VPN_PASSWORD
  writeKerioConfigParam autodetect_fingerprint boolean true
  writeKerioConfigParam autodetect_accept boolean true
}

setupVpn() {
  writeKerioConfig

  if [ ! -f "/tmp/kerio-control-vpnclient-${VPN_CLIENT_VERSION}-linux-amd64.deb" ]; then
    wget http://cdn.kerio.com/dwn/control/control-${VPN_CLIENT_VERSION}/kerio-control-vpnclient-${VPN_CLIENT_VERSION}-linux-amd64.deb
  else
    sudo /etc/init.d/kerio-kvc stop
    echo "Kerio stop delay"
    sleep 2
  fi

  sudo debconf-set-selections kerio.params
  sudo dpkg -i /tmp/kerio-control-vpnclient-${VPN_CLIENT_VERSION}-linux-amd64.deb
  sudo /etc/init.d/kerio-kvc start

  echo "Kerio warm-up delay"
  sleep 2

  setMTU

  waitForKvnet
}

try_verify() {
  curl -s --max-time $WAIT_KVN_TIMEOUT --cookie "TOTP_CONTROL=${VPN_AUTH_CODE}" http://10.212.255.245:4080//nonauth/totpVerify.cs
  curl_retval=$?
}

sudo apt update && sudo apt install -y wget curl debconf openssl

cd /tmp

setup_attempts=1
while [ $setup_attempts -le $MAX_SETUP_ATTEMPTS ]; do
  setupVpn && break
  echo "VPN setup failed. Attempt: $setup_attempts"
  DESIRED_MTU=$((DESIRED_MTU - decrement_value))  # Decrement the MTU
  if [ $DESIRED_MTU -lt $MINIMAL_MTU ]; then
    DESIRED_MTU=$MINIMAL_MTU  # Ensure we don't go below the minimal MTU
  fi
  setup_attempts=$((setup_attempts + 1))
done

if [ $setup_attempts -gt $MAX_SETUP_ATTEMPTS ]; then
  echo "Error! VPN setup failed after $MAX_SETUP_ATTEMPTS attempts"
  echo "Kerio VPN Client logs:"
  echo "init.log:"
  sudo cat /var/log/kerio-kvc/init.log
  echo "error.log:"
  sudo cat /var/log/kerio-kvc/error.log
  echo "debug.log:"
  sudo cat /var/log/kerio-kvc/debug.log
  exit 1
fi

retry_count=1
try_verify
while [ $curl_retval -ne 0 -a $retry_count -lt $MAX_CURL_ATTEMPT ]; do
  echo "curl failed with ${curl_retval}. retrying (${retry_count})..."
  retry_count=$((retry_count + 1))
  sleep 3
  try_verify
done

if [ x"${curl_retval}" != x"0" ]; then
  echo "Error! curl failed ${retry_count} times"
  exit $curl_retval
fi

echo "VPN connection is established!"
exit 0
