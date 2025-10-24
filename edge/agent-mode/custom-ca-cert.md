# Intro
This script is a simple example of how to deploy an Edge Agent using the Edge Agent Mode, with a custom CA cert. Make sure not to miss the following: 

- Create a registration token in Palette and use that for the **TOKEN** variable in the script
- If you're using a self-hosted instance of Palette, you need to change the **paletteEndpoint** to point to your self-hosted instance. Make sure to have a valid FQDN and a valid certificate for the self-hosted instance. 
- The **name** variable will be used for the hostname of the Edge device and the name shown in Palette. This name must be unique within the Palette tenant.
- Add your custom CA cert to the **caCerts** field in the script. Make sure to use the correct format for the cert. If you are using the self-signed certs created by Palette, you can find the CA in System Console -> Administration -> System Address. Copy the CA and decode it using base64. 

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
      paletteEndpoint: 192.168.x.x
      name: new-hostname
      caCerts:
      - |
         -----BEGIN CERTIFICATE-----
         FAKE-jCCA3qgAwIBAgIQHmz68oSo+ESDAesLIZk58zANBgkqhkiG9w0BAQsFADBr
         MQwwCgYDVQQGEwNVU0ExEzARBgNVBAgTCkNhbGlmb3JuaWExGzAZBgNVBAoTElNw
         ZWN0cm8gQ2xvdWQgSW5jLjEQMA4GA1UECxMHUGFsZXR0ZTEXMBUGA1UEAxMOQ0Eg
         Q2VydGlmaWNhdGUwHhcNMjUxMDEyMjEzNjQ3WhcNMzUxMDEwMjEzNjQ3WjBrMQww
         CgYDVQQGEwNVU0ExEzARBgNVBAgTCkNhbGlmb3JuaWExGzAZBgNVBAoTElNwZWN0
         cm8gQ2xvdWQgSW5jLjEQMA4GA1UECxMHUGFsZXR0ZTEXMBUGA1UEAxMOQ0EgQ2Vy
         dGlmaWNhdGUwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDiF3rM2FW1
         +stK2Oiw1owO17Qquy5BZ1CxXLPJsbS0tzIGFz0hLZi8olCqYg11kmZ77quXV60M
         0xcLv2Lxxk3uoj5eSLBjn3UDoBl4bH6Vdiex4AMcbV3hWBFRH9AGFqFCORuoJTal
         o9DFtxNpBLfR7EXS4jDumNXyRLrnRaPFUs0JFIpShNr4PAR8YEJU5VjDf3AqnHZi
         u1cmjtdYGZ0c49F+ZQ4yRllneL0OcIpbogVqJkxManolrBt3tayhYXXDdaVG5wb3
         dLi53VKIxoSuvbC4QPeUK8ASVi1V62l/m6OFyoBXfNq1DZd6fig=
         -----END CERTIFICATE-----
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