#!/bin/bash

# Prompt for email and domain
read -p "Enter your email: " USER_EMAIL
read -p "Enter your domain: " USER_DOMAIN

# Update and upgrade packages
echo "Updating and upgrading packages..."
apt-get update
apt-get upgrade -y

# Install required packages
echo "Installing required packages..."
apt-get install -y vim ufw socat nginx

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
echo "Configuring UFW..."
ufw enable
ufw allow 80/tcp
ufw allow 443/tcp

# Install acme.sh and register account
echo "Installing acme.sh and registering account..."
curl https://get.acme.sh | sh
export CF_Email="$USER_EMAIL"
echo -n "Enter your Cloudflare API Key: "
read CF_Key
echo
export CF_Key
~/.acme.sh/acme.sh --register-account -m $USER_EMAIL

# Issue SSL certificate and configure nginx
echo "Issuing SSL certificate and configuring nginx..."

systemctl stop nginx
~/.acme.sh/acme.sh --issue -d $USER_DOMAIN --standalone -k ec-256

systemctl start nginx
systemctl enable nginx

# Install V2Ray
echo "Installing V2Ray..."
mkdir -p /etc/v2ray
~/.acme.sh/acme.sh --installcert -d $USER_DOMAIN \
--ecc --fullchain-file /etc/v2ray/v2ray.crt \
--key-file /etc/v2ray/v2ray.key \
--reloadcmd "service nginx force-reload"
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-dat-release.sh)
systemctl enable v2ray

# Generate UUID
uuid=$(cat /proc/sys/kernel/random/uuid)

# Create V2Ray config file
echo "Configuring V2Ray..."
config_path="/usr/local/etc/v2ray/config.json"
cat > "$config_path" <<EOF
{
	"inbounds": [
		{
			"port": 10001,
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
			"settings": {},
			"tag": "direct"
		},
		{
			"protocol": "socks",
			"settings": {
				"servers": [
					{
						"address": "127.0.0.1",
						"port": 40000
					}
				]
			},
			"tag": "warp-out"
		}
	],
	"routing": {
		"domainStrategy": "IPIfNonMatch",
		"rules": [
			{
				"type": "field",
				"domain": [
					"geosite:openai",
					"anthropic.com",
					"api.anthropic.com",
					"claude.ai"
				],
				"outboundTag": "warp-out"
			}
		]
	}
}
EOF

# Append Nginx configuration to nginx.conf http block
echo "Configuring nginx..."
nginx_conf="/etc/nginx/nginx.conf"
nginx_config_to_append="
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    ssl_certificate     /etc/v2ray/v2ray.crt;
    ssl_certificate_key /etc/v2ray/v2ray.key;

    ssl_protocols       TLSv1 TLSv1.1 TLSv1.2;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    server_name         $USER_DOMAIN;

    location /ray {
        if (\$http_upgrade != \"websocket\") {
            return 404;
        }
        proxy_redirect     off;
        proxy_pass         http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection \"upgrade\";
        proxy_set_header   Host \$host;
    }
}"

# 先备份原始nginx.conf
cp "$nginx_conf" "${nginx_conf}.bak"

# 使用awk将nginx.conf的内容分割并将$nginx_config_to_append插入到适当的位置
awk -v append="$nginx_config_to_append" '
  /http {/ {
    print
    print append
    next
  }
  1
' "${nginx_conf}.bak" > "$nginx_conf"

# Reload Nginx
echo "Reloading nginx..."
nginx -s reload

# Restart V2Ray
echo "Restarting V2Ray..."
systemctl restart v2ray

# Print UUID and port
echo "==============================================="
echo "Setup Complete!"
echo "Generated UUID: $uuid"
echo "Port: 443"
echo "==============================================="

exit 0