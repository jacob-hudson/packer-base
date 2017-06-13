#!/bin/bash

# Exit on errors and undefined variables
set -e -u

# Setup temp file
tmpfile=$(mktemp /tmp/packer.XXXXX)

# Trap signals
# https://www.turnkeylinux.org/blog/shell-error-handling
for sig in INT TERM EXIT; do
   trap "
      if [[ $sig != EXIT ]]; then
         rm $tmpfile
         trap - $sig EXIT
         kill -s $sig $$
      fi
   " $sig
done

# Usage routine
usage() {
   echo "usage: $(basename $0) -c -m -q o/s [ insecure unencrypted encrypted ]"
   echo "   -c  complex  password"
   echo "   -m  minimize (dd /dev/zeros)"
   echo "   -q  quiet"
   exit 1
}

# Find directory that this script resides in
if [[ "$0" =~ "/" ]]; then
   rundir=$(cd $(dirname $0); pwd)
else
   rundir=$(pwd)
fi
pushd $rundir >/dev/null 2>&1

# Get command line options
# d = debug
# m = minimize (dd /dev/zero)
# s = password (use simple password "packer" for root)
quiet=no
minimize=no
complexpass=no
while getopts cmq c
do
  case $c in
  c)  complexpass=yes ;;
  m)  minimize=yes ;;
  q)  quiet=yes ;;
  \?)  usage
  exit 2;;
  esac
done
shift `expr $OPTIND - 1`

# debug
[[ $quiet == yes ]] || set -xv

# Only create virtualbox for now
providers="virtualbox"

# Arguments
os=$1
security=$2


case $security in
encrypted|unencrypted|insecure) : ;;
*) usage ;;
esac

# Set directory paths
files=${rundir}/repos/packer-$os
artifacts=${rundir}/artifacts/$os
http=${rundir}/http

[ -d $artifacts ] || mkdir -p $artifacts
[ -d $http ] || mkdir $http

# This script expects paths relative to packer/
pushd $rundir >/dev/null 2>&1

# Mac OS X openssl sha256sum and gtr
openssl=openssl
tr=tr
case $(uname -s) in
Darwin)
   # OpenSSL for creating a password hash
   if ! brew list openssl > /dev/null; then
      brew install openssl
   fi
   openssl=$(brew list openssl | awk '$1 ~ "bin/openssl$" {print $1}' | head -1)

   # sha2 for sha 256 checksums
   if ! brew list sha2 > /dev/null; then
      brew install sha2
   fi
   sha2=$(brew list sha2 | awk '$1 ~ "bin/sha2" {print $1}')
   sha256sum() {
      $sha2 -256 $*
   }

   # gtr from coreutils
   tr=gtr
   ;;
esac

# If running locally pull repositories.

./pull_repos.sh $os

# Copy template to profile
profile=${http}/${os}-${security}.cfg
[ -f $profile ] && rm $profile
cp ${files}/profile.cfg ${profile}

# Create random root password
password=$(cat /dev/urandom | $tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1)
[ $complexpass == yes ] || password=packer
echo $password > ${artifacts}/rootpwd
chmod 600 ${artifacts}/rootpwd

# TBD: Figure out how to hash the password so linux takes an encrypted password
# hash=$(echo -n $password | $openssl passwd -1 -stdin)
# perl -pi -e s|__password__|${hash}|" $profile

# For now, tell the profile to use a plaintext and substitute the straight password field
perl -pi -e "s|--iscrypted|--plaintext|" $profile
perl -pi -e "s|__password__|${password}|" $profile


# minimize: DD /dev/zeros to make for better compression
if [[ ${minimize} = yes ]]; then
   perl -pi -e "s|^#minimize# ||" $profile
fi


# Substitute values for security fields
case $os in
centos*|rhel*)
   if [ $security = unencrypted -o $security = insecure ]; then
      perl -pi -e "s| --encrypt --passphrase=packer||" $profile
   fi

   if [ $security = insecure ]; then
      perl -pi -e "s|firewall --enabled --ssh|firewall --disabled|" $profile
      perl -pi -e "s|selinux --enforcing|selinux --disabled|" $profile
   fi
   ;;
esac

# Create base OVF
for provider in $providers
do :
   # Build packer base box
   packer build -force -only=${provider}-iso -var password=${password} -var profile=$(basename ${profile}) ${files}/packer_base.json

   # Repackage as a vagrant box
   packer build -force -only=${provider}-ovf -var password=${password} ${files}/packer_vagrant.json

done

# Create vagrant file
cat > artifacts/$os/Vagrantfile << EOF
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure(2) do |config|
  config.ssh.username = ENV["USERNAME"] || ENV["USER"]
  config.ssh.private_key_path = "~/.ssh/id_rsa"
  config.vm.box = "${os}-virtualbox.box"
  config.vm.define vm_name = "${os}-packer"
end
EOF

# Create vagrant scripts
cat > artifacts/${os}/vagrant_up.sh << EOF
vagrant up
echo -n "${os}-packer ansible_ssh_host=127.0.0.1 ansible_ssh_port=" > ansible-inventory
echo -n \$(vagrant ssh-config | grep Port | awk '{print \$2}') >> ansible-inventory
EOF
chmod +x artifacts/${os}/vagrant_up.sh

cat > artifacts/${os}/vagrant_down.sh << EOF
vagrant destroy -f
vagrant box remove ${os}-virtualbox.box
EOF
chmod +x artifacts/${os}/vagrant_down.sh

cat > artifacts/$os/ansible.cfg << EOF
[defaults]
# Inventory file
inventory=ansible-inventory


# Requires remote sudoers to not require tty
pipelining = True

# Try UTF-8
module_lang    = UTF-8
EOF

# Cleanup
rm -r artifacts/${os}/${os}-${provider}
rm http/${os}-${security}
