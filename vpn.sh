#!/usr/bin/env sh

MAX_RETRY_COUNT=5
VPN_CLIENT_VERSION=$1
VPN_USERNAME=$2
VPN_PASSWORD=$3
VPN_AUTH_CODE=$4

waitForKvnet() {
    start_time=$(date +%s)
    while ! ip a show kvnet up | grep inet 2>/dev/null; do
        current_time=$(date +%s)
        elapsed_time=$(($current_time - $start_time))
        echo "Waiting for kvnet to start... Elapsed time: $elapsed_time seconds"
        if [ $elapsed_time -ge 180 ]; then
            echo "Error: kvnet did not start within 3 minutes"
            echo "Details of kvnet interface:"
            ip addr show kvnet
            exit 1
        fi
        sleep 1
    done
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

sudo apt update && sudo apt install -y wget curl debconf openssl

cd /tmp

writeKerioConfig

wget http://cdn.kerio.com/dwn/control/control-${VPN_CLIENT_VERSION}/kerio-control-vpnclient-${VPN_CLIENT_VERSION}-linux-amd64.deb

sudo debconf-set-selections kerio.params
sudo dpkg -i /tmp/kerio-control-vpnclient-${VPN_CLIENT_VERSION}-linux-amd64.deb
sudo /etc/init.d/kerio-kvc start

echo "Kerio warm-up delay"
sleep 2

waitForKvnet

try_verify() {
  curl -s --cookie "TOTP_CONTROL=${VPN_AUTH_CODE}" http://10.212.255.245:4080//nonauth/totpVerify.cs
  curl_retval=$?
}

retry_count=1
try_verify
while [ $curl_retval -ne 0 -a $retry_count -lt $MAX_RETRY_COUNT ]; do
  echo "curl failed with ${curl_retval}. retrying (${retry_count})..."
  retry_count=$((retry_count + 1))
  sleep 3
  try_verify
done

if [ x"${curl_retval}" != x"0" ]; then
  echo "Error! curl failed ${retry_count} times"
  exit $curl_retval
fi

echo "vpn connection is done!"
exit 0
