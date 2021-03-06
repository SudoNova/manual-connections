#!/bin/bash
# Copyright (C) 2020 Private Internet Access, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# This function allows you to check if the required tools have been installed.
function check_tool() {
  cmd=$1
  if ! command -v $cmd &>/dev/null
  then
    echo "$cmd could not be found"
    echo "Please install $cmd"
    return 1
  fi
}
# Now we call the function to make sure we can use wg-quick, curl and jq.
check_tool curl
check_tool jq
check_tool openvpn
check_tool sed

SCRIPTDIR=$(dirname $(realpath $BASH_SOURCE))

# Check if manual PIA OpenVPN connection is already initialized.
# Multi-hop is out of the scope of this repo, but you should be able to
# get multi-hop running with both OpenVPN and WireGuard.
adapter_check="$( ip a s tun06 2>&1 )"
should_read="Device \"tun06\" does not exist"
pid_filepath="$SCRIPTDIR/pia_pid"
if [[ "$adapter_check" != *"$should_read"* ]]; then
  echo The tun06 adapter already exists, that interface is required
  echo for this configuration.
  if [ -f "$pid_filepath" ]; then
    old_pid="$( cat "$pid_filepath" )"
    old_pid_name="$( ps -p "$old_pid" -o comm= )"
    if [[ $old_pid_name == 'openvpn' ]]; then
      echo
      echo It seems likely that process $old_pid is an OpenVPN connection
      echo that was established by using this script. Unless it is closed
      echo you would not be able to get a new connection.
      echo -n "Do you want to run $ kill $old_pid (Y/n): "
      read close_connection
    fi
    if echo ${close_connection:0:1} | grep -iq n ; then
      echo Closing script. Resolve tun06 adapter conflict and run the script again.
      return 1
    fi
    echo Killing the existing OpenVPN process and waiting 5 seconds...
    kill $old_pid
    sleep 5
  fi
fi

# PIA currently does not support IPv6. In order to be sure your VPN
# connection does not leak, it is best to disabled IPv6 altogether.
# IPv6 can also be disabled via kernel commandline param, so we must
# first check if this is the case.
if [[ -f /proc/net/if_inet6 ]] &&
  [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6) -ne 1 ||
     $(sysctl -n net.ipv6.conf.default.disable_ipv6) -ne 1 ]]
then
  echo 'You should consider disabling IPv6 by running:'
  echo 'sysctl -w net.ipv6.conf.all.disable_ipv6=1'
  echo 'sysctl -w net.ipv6.conf.default.disable_ipv6=1'
fi

#  Check if the mandatory environment variables are set.
if [[ ! $OVPN_SERVER_IP ||
  ! $OVPN_HOSTNAME ||
  ! $PIA_TOKEN ||
  ! $CONNECTION_SETTINGS ]]; then
  echo 'This script requires 4 env vars:'
  echo 'PIA_TOKEN           - the token used for authentication'
  echo 'OVPN_SERVER_IP      - IP that you want to connect to'
  echo 'OVPN_HOSTNAME       - name of the server, required for ssl'
  echo 'CONNECTION_SETTINGS - the protocol and encryption specification'
  echo '                    - available options for CONNECTION_SETTINGS are:'
  echo '                        * openvpn_udp_standard'
  echo '                        * openvpn_udp_strong'
  echo '                        * openvpn_tcp_standard'
  echo '                        * openvpn_tcp_strong'
  echo
  echo You can also specify optional env vars:
  echo "PIA_PF                - enable port forwarding"
  echo "PAYLOAD_AND_SIGNATURE - In case you already have a port."
  echo
  echo An easy solution is to just run get_region_and_token.sh
  echo as it will guide you through getting the best server and
  echo also a token. Detailed information can be found here:
  echo https://github.com/pia-foss/manual-connections
  return 1
fi

# Create a credentials file with the login token
echo "Trying to write $SCRIPTDIR/pia.ovpn...
"
mkdir -p "$SCRIPTDIR"
rm -f "$SCRIPTDIR"/credentials "$SCRIPTDIR"/route_info
echo ${PIA_TOKEN:0:62}"
"${PIA_TOKEN:62} > "$SCRIPTDIR"/credentials || return 1
chmod 600 "$SCRIPTDIR"/credentials

# Translate connection settings variable
IFS='_'
read -ra connection_settings <<< "$CONNECTION_SETTINGS"
IFS=' '
protocol="${connection_settings[1]}"
encryption="${connection_settings[2]}"

prefix_filepath="openvpn_config/standard.ovpn"
if [[ $encryption == "strong" ]]; then
  prefix_filepath="openvpn_config/strong.ovpn"
fi

if [[ $protocol == "udp" ]]; then
  if [[ $encryption == "standard" ]]; then
    port=1198
  else
    port=1197
  fi
else
  if [[ $encryption == "standard" ]]; then
    port=502
  else
    port=501
  fi
fi

# Create the OpenVPN config based on the settings specified
cat "$SCRIPTDIR/$prefix_filepath" > "$SCRIPTDIR"/pia.ovpn || return 1
echo remote $OVPN_SERVER_IP $port $protocol >> "$SCRIPTDIR"/pia.ovpn

# Copy the up/down scripts to "$SCRIPTDIR"/
# based upon use of PIA DNS
if [ "$PIA_DNS" != true ]; then
  cp "$SCRIPTDIR/openvpn_config/openvpn_up.sh" "$SCRIPTDIR"/
  cp "$SCRIPTDIR/openvpn_config/openvpn_down.sh" "$SCRIPTDIR"/
  echo This configuration will not use PIA DNS.
  echo If you want to also enable PIA DNS, please start the script
  echo with the env var PIA_DNS=true. Example:
  echo $ OVPN_SERVER_IP=\"$OVPN_SERVER_IP\" OVPN_HOSTNAME=\"$OVPN_HOSTNAME\" \
    PIA_TOKEN=\"$PIA_TOKEN\" CONNECTION_SETTINGS=\"$CONNECTION_SETTINGS\" \
    PIA_PF=true PIA_DNS=true . \"$SCRIPTDIR/connect_to_openvpn_with_token.sh\"
else
  cp "$SCRIPTDIR/openvpn_config/openvpn_up_dnsoverwrite.sh" "$SCRIPTDIR"/openvpn_up.sh
  cp "$SCRIPTDIR/openvpn_config/openvpn_down_dnsoverwrite.sh" "$SCRIPTDIR"/openvpn_down.sh
fi

# Replace $SCRIPTDIR with its value in final script
sed -i "s,\$SCRIPTDIR,$SCRIPTDIR,g" "$SCRIPTDIR/openvpn_up.sh"
sed -i "s,\$SCRIPTDIR,$SCRIPTDIR,g" "$SCRIPTDIR/openvpn_down.sh"
sed -i "s,\$SCRIPTDIR,$SCRIPTDIR,g" "$SCRIPTDIR/pia.ovpn"

# Start the OpenVPN interface.
# If something failed, stop this script.
# If you get DNS errors because you miss some packages,
# just hardcode /etc/resolv.conf to "nameserver 10.0.0.242".
#rm -f "$SCRIPTDIR"/debug_info
echo "
Trying to start the OpenVPN connection..."
openvpn --daemon \
  --config "$SCRIPTDIR/pia.ovpn" \
  --writepid "$SCRIPTDIR/pia_pid" \
  --log "$SCRIPTDIR/debug_info" \
  $OVPN_OPTS || return 1

echo "
The OpenVPN connect command was issued.

Confirming OpenVPN connection state... "

# Check if manual PIA OpenVPN connection is initialized.
# Manually adjust the connection_wait_time if needed
connection_wait_time=10
confirmation="Initialization Sequence Complete"
for (( timeout=0; timeout <=$connection_wait_time; timeout++ ))
do
  sleep 1
  if grep -q "$confirmation" "$SCRIPTDIR"/debug_info; then
    connected=true
    break
  fi
done

ovpn_pid="$( cat "$SCRIPTDIR"/pia_pid )"
gateway_ip="$( cat "$SCRIPTDIR"/route_info )"

# Report and exit if connection was not initialized within 10 seconds.
if [ "$connected" != true ]; then
  echo "The VPN connection was not established within 10 seconds."
  kill $ovpn_pid
  return 1
fi

echo "Initialization Sequence Complete!

At this point, internet should work via VPN.
"

echo "OpenVPN Process ID: $ovpn_pid
VPN route IP: $gateway_ip

To disconnect the VPN, run:

--> sudo kill $ovpn_pid <--
"

# This section will stop the script if PIA_PF is not set to "true".
if [ "$PIA_PF" != true ]; then
  echo
  echo If you want to also enable port forwarding, please start the script
  echo with the env var PIA_PF=true. Example:
  echo $ OVPN_SERVER_IP=\"$OVPN_SERVER_IP\" OVPN_HOSTNAME=\"$OVPN_HOSTNAME\" \
    PIA_TOKEN=\"$PIA_TOKEN\" CONNECTION_SETTINGS=\"$CONNECTION_SETTINGS\" \
    PIA_PF=true . \"$SCRIPTDIR/connect_to_openvpn_with_token.sh\"
  exit
fi

echo "
This script got started with PIA_PF=true.
Starting procedure to enable port forwarding by running the following command:
$ PIA_TOKEN=\"$PIA_TOKEN\" \\
  PF_GATEWAY=\"$gateway_ip\" \\
  PF_HOSTNAME=\"$OVPN_HOSTNAME\" \\
  . \"$SCRIPTDIR/port_forwarding.sh\"
"

PIA_TOKEN=$PIA_TOKEN \
  PF_GATEWAY="$gateway_ip" \
  PF_HOSTNAME="$OVPN_HOSTNAME" \
  . "$SCRIPTDIR/port_forwarding.sh"
