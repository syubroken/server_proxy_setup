#!/bin/bash

# Update and upgrade packages
apt-get update
apt-get upgrade -y

# Install required packages
apt-get install -y vim ufw socat

# Create and write to .vimrc
cat > ~/.vimrc <<EOF
set nocompatible
set encoding=utf-8
set fileencodings=utf-8,Chinese
set tabstop=4
set shiftwidth=4
set number
set autoindent
set smartindent
set nobackup
set hlsearch
set display=lastline
syntax on
EOF

# Enable and configure UFW
ufw enable
ufw allow 80/tcp
ufw allow 443/tcp

# Install acme.sh and register account
curl https://get.acme.sh | sh
export CF_Email="senyz2040@163.com"
echo "Enter your Cloudflare API Key:"
read CF_Key
export CF_Key
~/.acme.sh/acme.sh --register-account -m $CF_Email

# Issue SSL certificate and configure nginx
~/.acme.sh/acme.sh --issue -d senyzloss.life --standalone -k ec-256
apt-get install -y nginx
systemctl enable nginx
systemctl start nginx

# Install V2Ray
mkdir /etc/v2ray
~/.acme.sh/acme.sh --installcert -d senyzloss.life \
--ecc --fullchain-file /etc/v2ray/v2ray.crt \
--key-file /etc/v2ray/v2ray.key \
--reloadcmd "service nginx force-reload"
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) --version v4.45.0
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-dat-release.sh)
systemctl enable v2ray

# Generate UUID
uuid=$(cat /proc/sys/kernel/random/uuid)

# Create V2Ray config file
config_path="/usr/local/etc/v2ray/config.json"
cat > "$config_path" <<EOF
{
	"inbounds": [
		{
			"port": 443,
			"listen": "127.0.0.1",
			"protocol": "vmess",
			"settings": {
				"clients": [
					{
						"id": "$uuid",
						"alterId": 0
					}
				]
			},
			"streamSettings": {
				"network": "ws",
				"wsSettings": {
					"path": "/ray"
				}
			}
		}
	],

	"outbounds": [
		{
			"protocol": "freedom",
			"settings": {}
		}
	]
}
EOF

# Append Nginx configuration to nginx.conf http block
nginx_conf="/etc/nginx/nginx.conf"
nginx_config_to_append="
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    ssl_certificate     /etc/v2ray/v2ray.crt;
    ssl_certificate_key /etc/v2ray/v2ray.key;

    ssl_protocols       TLSv1 TLSv1.1 TLSv1.2;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    server_name         senyzloss.life;

    location /ray {
        if (\$http_upgrade != \"websocket\") {
            return 404;
        }
        proxy_redirect     off;
        proxy_pass         http://127.0.0.1:443;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection \"upgrade\";
        proxy_set_header   Host \$host;
    }
}"

# Insert nginx_config_to_append into nginx.conf http block
sed -i "/http {/a $nginx_config_to_append" "$nginx_conf"

# Reload Nginx
nginx -s reload

# Restart V2Ray
systemctl restart v2ray

# Print UUID and port
echo "Generated UUID: $uuid"
echo "Port: 443"
