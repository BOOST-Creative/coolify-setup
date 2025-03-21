#! /bin/bash

# exit on error
set -e

# clear screen
clear

# variables
GREEN="\e[32m"
CYAN="\e[36m"
YELLOW="\e[33m"
ENDCOLOR="\e[0m"
CUR_TIMEZONE=$(timedatectl show | grep zone | sed 's/Timezone=//g')
KOPIA_PASSWORD=$(tr </dev/urandom -dc A-Z-a-z-0-9 | head -c"${1:-10}")
ARCHITECTURE=$(dpkg --print-architecture)

# intro message
echo -e "${GREEN}Welcome! This script should be run as the root user on a new Debian or Ubuntu server.${ENDCOLOR}\n"

# change timezone (works on debian / ubuntu / fedora)
read -r -p "$(echo -e "The system time zone is ${YELLOW}$CUR_TIMEZONE${ENDCOLOR}. Do you want to change it (y/n)?${ENDCOLOR} ")" yn
if [[ $yn =~ ^[Yy]$ ]]; then
  if command -v dpkg-reconfigure &>/dev/null; then
    dpkg-reconfigure tzdata
  else
    read -r -p "Enter time zone: " new_timezone
    if timedatectl set-timezone "$new_timezone"; then
      echo -e "${GREEN}Time zone has changed to: $new_timezone ${ENDCOLOR}"
    else
      echo -e "Run ${CYAN}timedatectl list-timezones${ENDCOLOR} to view all time zones"
      exit
    fi
  fi
fi

# create user account (works on debian / ubuntu / fedora)
read -r -p "$(echo -e "\nEnter username for the user to be created: ")" username
while [[ ! $username =~ ^[a-z][-a-z0-9]*$ ]]; do
  read -r -p "Invalid format. Enter username for the user to be created: " username
done
useradd -m -s /bin/bash "$username"
passwd "$username"
usermod -aG sudo "$username" || usermod -aG wheel "$username"

echo ""

# SSH port prompt
read -r -p "Which port do you want to use for SSH (not 6900-6905 please)? " ssh_port
while ((ssh_port < 1000 || ssh_port > 65000)); do
  read -r -p "Please use a number between 1000 and 65000: " ssh_port
done

# add ssh key
mkdir -p "/home/$username/.ssh"
# check if root has authorized_keys already
if [ -s /root/.ssh/authorized_keys ]; then
  cp /root/.ssh/authorized_keys "/home/$username/.ssh/authorized_keys"
else
  # if no keys, ask for key instead
  read -r -p "Please paste your public SSH key: " sshkey
  echo "$sshkey" >>"/home/$username/.ssh/authorized_keys"
fi
# fix permissions
chown -R "$username": "/home/$username/.ssh"

# add / update packages
echo -e "${CYAN}Updating system & packages...${ENDCOLOR}"

# eza
sudo mkdir -p /etc/apt/keyrings
wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | sudo tee /etc/apt/sources.list.d/gierens.list
sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list

# kopia
curl -s https://kopia.io/signing-key | gpg --dearmor -o /usr/share/keyrings/kopia-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/kopia-keyring.gpg] http://packages.kopia.io/apt/ stable main" | tee /etc/apt/sources.list.d/kopia.list

# yq for editing yml files
# wget https://github.com/mikefarah/yq/releases/download/v4.41.1/yq_linux_${ARCHITECTURE}.tar.gz -O - |
#   tar xz && mv yq_linux_${ARCHITECTURE} /usr/bin/yq
#

# meslo nerd font
wget https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0/Meslo.zip
mkdir -p /usr/share/fonts/truetype/
unzip Meslo.zip -d /usr/share/fonts/truetype/
rm Meslo.zip

# update system - apt update runs in docker script
apt update
apt upgrade -y
apt install kopia unattended-upgrades zsh fzf bat eza zoxide ncdu apache2-utils -y

# neovim
curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
sudo tar -C /opt -xzf nvim-linux-x86_64.tar.gz

# unattended-upgrades
echo -e "${CYAN}Setting up unattended-upgrades...${ENDCOLOR}"
dpkg-reconfigure --priority=low unattended-upgrades

# install coolify
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash

# docker stuff
echo -e "${CYAN}Setting up docker containers...${ENDCOLOR}"

# copy files
mkdir -p "/home/$username/server"
cp /tmp/cs/docker-compose.yml "/home/$username/server/docker-compose.yml"
cp /tmp/cs/firewall.sh "/home/$username/firewall.sh"
sed -i "s/REPLACE_ME/$ssh_port/" "/home/$username/firewall.sh"

# replace docker compose file with user input, and start
sed -i "s/CHANGE_TO_USERNAME/$username/" "/home/$username/server/docker-compose.yml"
# sed -i "s/USER_UID/$(id -u $username)/" "/home/$username/server/docker-compose.yml"
# sed -i "s/USER_GID/$(id -g $username)/" "/home/$username/server/docker-compose.yml"
# sed -i "s|USER_TIMEZONE|$(timedatectl show | grep zone | sed 's/Timezone=//g')|" "/home/$username/server/docker-compose.yml"
docker compose -f "/home/$username/server/docker-compose.yml" up -d

# fix permissions
chown "$username": "/home/$username/sites" "/home/$username/server/docker-compose.yml" "/home/$username/firewall.sh"

# nobody user bc that's what wp container uses
chown -R nobody:nogroup "/home/$username/server/filebrowser"

# add user to docker users
usermod -aG docker "$username"

# generate password file for kopia server
htpasswd -bc /root/kopiap.txt kopia "$KOPIA_PASSWORD" >/dev/null 2>&1

# set up automated jobs with systemd
cp /tmp/cs/systemd/* /etc/systemd/system
sed -i "s/USERNAME/$username/" /etc/systemd/system/kopiaServer.service

systemctl daemon-reload
# systemd timer to optimize images every day at 12:30am
systemctl start optimize_images.timer
systemctl enable optimize_images.timer >/dev/null 2>&1
# kopia server
systemctl start kopiaServer.service
systemctl enable kopiaServer.service >/dev/null 2>&1

# update SSH config
echo -e "\n${CYAN}Updating SSH config...${ENDCOLOR}"
{
  echo "Port $ssh_port"
  echo "PermitRootLogin prohibit-password"
  echo "PubkeyAuthentication yes"
  echo "PasswordAuthentication no"
  echo "X11Forwarding no"
} >>/etc/ssh/sshd_config

echo -e "${CYAN}Restarting SSH daemon...${ENDCOLOR}\n"
systemctl restart sshd

# add boost cli
mkdir -p "/home/$username/.local/bin"
wget -O "/home/$username/.local/bin/boost.tar.gz" "https://github.com/BOOST-Creative/boost-server-cli/releases/download/v0.0.5/boost-server-cli_0.0.5_linux_$ARCHITECTURE.tar.gz"
tar -zxvf "/home/$username/.local/bin/boost.tar.gz" -C "/home/$username/.local/bin" boost
rm "/home/$username/.local/bin/boost.tar.gz"
chown -R "$username:" "/home/$username/.local/bin"

# clone wordpress repo and copy config
mkdir -p "/etc/$username/mariadb"
mkdir -p "/etc/$username/valkey"
git clone https://github.com/BOOST-Creative/coolify-wordpress-8 "/tmp/wp"
cp "/tmp/wp/config/valkey.conf" "/etc/$username/valkey/valkey.conf"
cp "/tmp/wp/config/my.cnf" "/etc/$username/mariadb/my.cnf"
cp "/tmp/wp/config/db-entrypoint.sh" "/etc/$username/mariadb/db-entrypoint.sh"

# verify ssh key is correct
cat "/home/$username/.ssh/authorized_keys"
read -r -p "$(echo -e "\nIs the above SSH key(s) correct (y/n)? ")" ssh_correct
while [[ ! $ssh_correct =~ ^[Yy]$ ]]; do
  read -r -p "Please paste your public SSH key: " sshkey
  echo "$sshkey" >>"/home/$username/.ssh/authorized_keys"
  cat "/home/$username/.ssh/authorized_keys"
  read -r -p "$(echo -e "\nIs the above SSH key(s) correct (y/n)? ")" ssh_correct
done

# copy zshrc
cp /tmp/cs/.zshrc "/home/$username/.zshrc"

# change shell to zsh
chsh -s /bin/zsh "$username"

# lazyvim
# mv ~/.config/nvim{,.bak}
git clone https://github.com/LazyVim/starter ~/.config/nvim --depth 1

# aliases / .bashrc stuff
{
  echo 'echo -e "\nFile Browser: \e[34mhttp://localhost:6900\n\e[0mKopia: \e[34mhttp://localhost:6901\e[0m (kopia:'"$KOPIA_PASSWORD"')\nWUD: \e[34mhttp://localhost:6902\n\n\e[0mRun ctop to manage containers and view metrics.\n"'
} >>"/home/$username/.zshrc"

# permissions again for good measure
chown -R "$username": "/home/$username"

# Success Message
echo -e "\n${GREEN}Setup complete 👍. Please log back in as $username on port $ssh_port.${ENDCOLOR}"
echo -e "${GREEN}Firewall script will run on first login.${ENDCOLOR}"
echo -e "${GREEN}Update your SSH config file with the info below${ENDCOLOR}"

echo -e "\n\033[1m🚨\e[31m ENABLE CLOUD FIREWALL NOW 🚨${ENDCOLOR}\n"

echo "Host $(hostname)"
echo "    HostName $(curl -s -4 ifconfig.me)"
echo "    Port $ssh_port"
echo "    User $username"
echo "    LocalForward 6901 127.0.0.1:6901"
echo "    LocalForward 6902 127.0.0.1:6902"
echo "    LocalForward 6903 127.0.0.1:6903"
echo "    ServerAliveInterval 60"
echo -e "    ServerAliveCountMax 10\n"

reboot
