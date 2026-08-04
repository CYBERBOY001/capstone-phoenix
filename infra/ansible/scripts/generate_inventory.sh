#!/bin/bash

CONTROL_PUBLIC=$(terraform output -raw control_plane_public_ip)
CONTROL_PRIVATE=$(terraform output -raw control_plane_private_ip)

WORKER_PUBLICS=($(terraform output -json worker_public_ips | jq -r '.[]'))
WORKER_PRIVATES=($(terraform output -json worker_private_ips | jq -r '.[]'))

cat > ../ansible/inventory/hosts.ini <<EOF
[server]
control-plane ansible_host=${CONTROL_PUBLIC} private_ip=${CONTROL_PRIVATE}

[agents]
EOF

for i in "${!WORKER_PUBLICS[@]}"; do
cat >> ../ansible/inventory/hosts.ini <<EOF
worker-$((i+1)) ansible_host=${WORKER_PUBLICS[$i]} private_ip=${WORKER_PRIVATES[$i]}
EOF
done

cat >> ../ansible/inventory/hosts.ini <<EOF

[k3s_cluster:children]
server
agents

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/capstone-key.pem
ansible_python_interpreter=/usr/bin/python3
EOF

echo "Inventory generated successfully."