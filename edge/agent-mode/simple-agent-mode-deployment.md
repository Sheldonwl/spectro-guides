# Intro
This script is a simple example of how to deploy an Edge Agent using the Edge Agent Mode. Make sure not to miss the following: 

- Create a registration token in Palette and use that for the **TOKEN** variable in the script
- If you're using a self-hosted instance of Palette, you need to change the **paletteEndpoint** to point to your self-hosted instance. Make sure to have a valid FQDN and a valid certificate for the self-hosted instance. If you don't, you'll need to add the CA cert to the user-data file and the self-signed cert should contain the IP or FQDN of the self-hosted instance as valid SANs.
- The **name** variable will be used for the hostname of the Edge device and the name shown in Palette. This name must be unique within the Palette cluster.

### Agent Mode prerequisites
  
```
sudo apt update && sudo apt upgrade -y
sudo apt-get install -y bash jq zstd rsync systemd-timesyncd conntrack iptables rsyslog --no-install-recommends
```

### Set token variable
```
export TOKEN=[CREATE AND ADD YOUR OWN REGISTRATION TOKEN]
```

### Create user-data file
```
cat << EOF > user-data
#cloud-config
install:
   reboot: true
   poweroff: false

stylus:
   vip:
      skip: false
   site:
      edgeHostToken: $TOKEN
      paletteEndpoint: api.spectrocloud.com
      name: new-hostname

stages:
   initramfs:
      - users:
         kairos:
            groups:
            - sudo
            passwd: kairos
EOF
```

### Install Edge Agent
```
export USERDATA=./user-data
curl --location --output ./palette-agent-install.sh https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install.sh
chmod +x ./palette-agent-install.sh
sudo --preserve-env ./palette-agent-install.sh
```

### Docs
Full list of available options: https://docs.spectrocloud.com/clusters/edge/edge-configuration/installer-reference/