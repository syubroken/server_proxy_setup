#!/bin/bash

generate_random_port() {
    echo $(( RANDOM % 50000 + 10000 ))
}

# 随机生成一个端口号，范围在10000到60000之间
RANDOM_PORT=$(generate_random_port)

# 检查端口号是否包含数字“4”或是否在ufw的防火墙规则中
while [[ $RANDOM_PORT =~ 4 ]] || ufw status numbered | grep -q " $RANDOM_PORT/"; do
    RANDOM_PORT=$(generate_random_port)
done

# 开启防火墙端口
ufw allow $RANDOM_PORT/tcp

# 备份原始的nginx.conf文件
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup

# 用新的端口号替换原来的端口号
sed -i "s/listen [0-9]* ssl;/listen $RANDOM_PORT ssl;/g" /etc/nginx/nginx.conf
sed -i "s/listen \[\:\]:[0-9]* ssl;/listen [::]:$RANDOM_PORT ssl;/g" /etc/nginx/nginx.conf

# 重新加载nginx配置
nginx -s reload

# 输出生成的端口号
echo "New port number: $RANDOM_PORT"
