# Run all commands on the NVIDIA device 

# Agent Mode prerequisites
sudo apt update && sudo apt upgrade -y
sudo apt-get install -y bash jq zstd rsync systemd-timesyncd conntrack iptables rsyslog --no-install-recommends

# Install jtop
sudo apt install -y python3-pip
sudo pip3 install jetson-stats

# Install Edge Agent - Feel free to tweak the user-data to fit your requirements. 
# Full list of available options: https://docs.spectrocloud.com/clusters/edge/edge-configuration/installer-reference/
export TOKEN=[CREATE AND ADD YOUR OWN REGISTRATION TOKEN]

cat << EOF > user-data
#cloud-config
install:
   reboot: true
   poweroff: false

stylus:
   path: /persistent/spectro
   vip:
      skip: false
   site:
      edgeHostToken: $TOKEN
      paletteEndpoint: api.spectrocloud.com
      projectName: Edge-AI
      name: nvidia-orin-agx

stages:
   initramfs:
      - users:
         kairos:
            groups:
            - sudo
            passwd: kairos
EOF

export USERDATA=./user-data
curl --location --output ./palette-agent-install.sh https://github.com/spectrocloud/agent-mode/releases/latest/download/palette-agent-install.sh
chmod +x ./palette-agent-install.sh
sudo --preserve-env ./palette-agent-install.sh
