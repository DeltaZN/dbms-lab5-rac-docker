#!/bin/sh
for file in ./Dockerfile-racnode/Dockerfile \
 dhclient-rac1-eth-priv.service \
 dhclient-rac1-eth-pub.service \
 dhclient-rac2-eth-priv.service \
 dhclient-rac2-eth-pub.service \
 README.md; do
    sed -i "s/$1/$2/g" $file
done