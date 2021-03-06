*ИСПОЛЬЗУЕЙТЕ НА СВОЙ СТРАХ И РИСК, МОГУТ БЫТЬ КОСЯКИ*
# dbms-lab5-rac-docker
Данное руководстко было создано с целью облегчить жизнь всем, кто будет делать 5ю лабу по РСХД/АСУБД(СУБД).
Основано на https://github.com/Seth-Miller/12c-rac-docker и https://se.ifmo.ru/~dima/dbadm/rac.html

## Подготовка

Я выпонял все действия на облачной виртуалке от google cloud(там есть три месяца бесплатно пользования).
В принципе всё это можно делать и у себя на виртуалке, главное, чтоб памяти хватило и всё.

К виртуалке необходимо подключить диск, который будет использоваться для asm. (в разных виртуалках делается по-разному, поэтому здесь не рассматривается)

Для виртуалки в качестве ОСи я взял Debian 10.

Скачиваем оракл с гелиоса 
```
scp -r -P 2222 s265082@helios.cs.ifmo.ru:/export/install/oracle/database/12.1.0.2 .
```

Устанавлиаем докер
```
sudo apt-get update
sudo apt-get install \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo \
  "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io
```

Во всех скриптах в описании вместо apprehensiveobserver надо использовать имена бд и узлов, которые указаны по варианту.
Для замены имён в скриптах 
```
./set_nodes_names.sh apprehensiveobserver имя_по_варианту
```


TODO

## How to use
This setup uses block devices for the ASM DATA diskgroup which the grid infrastructure requires during installation. The recommendation is to use three disks that are at least 4GB each in size.

It is important when creating the BIND and DHCPD containers that the BIND container is created first. The reason is that there is a key created as part of the BIND image build that DHCPD will use for dynamic dns updates and the key needs to exist when the DHCPD container is created.

The passwords for the non-privileged user accounts are all set to `oracle_4U`.

## Oracle installation files
Download the Oracle 12c Grid Infrastructure and Database installation files and unzip them in a directory on the host. The directory will be mounted as a volume in the RAC node containers for installation. The host directory used in this example is `/oracledata/stage/12.1.0.2`. Once unzipped, there should be a `grid` and `database` folder in `/oracledata/stage/12.1.0.2`.


## ASM
Udev is used in the RAC node containers to give the ASM block devices correct permissions and friendly names. ASMLib could also be used but I stopped using that a couple of years ago because it appears that it will go away at some point in favor of ASM Filter Driver (AFD).

Modify the `99-asm-disks.rules` file to reflect the devices on the host system that you have designated as ASM disks. For example, I have designated /dev/sdd, /dev/sde, and /dev/sdf as the three disks that will be used in my DATA ASM disk group.
```
KERNEL=="sdb", SYMLINK+="asmdisks/asm1", OWNER="54421", GROUP="54422"
```

NFS is used in the RAC node containers for the NDATA ASM disk group which uses file devices over NFS. The directory on the host OS that will be shared across the RAC node containers is `/oraclenfs`. Create three files on the host OS using `dd`.
```
sudo dd if=/dev/zero of=/oraclenfs/asm-clu-121-NDATA-disk1 bs=1024k count=2000
sudo dd if=/dev/zero of=/oraclenfs/asm-clu-121-NDATA-disk2 bs=1024k count=2000
sudo dd if=/dev/zero of=/oraclenfs/asm-clu-121-NDATA-disk3 bs=1024k count=2000

sudo chown 54421 /oraclenfs/asm*
sudo chgrp 54422 /oraclenfs/asm*
sudo chmod g+w /oraclenfs/asm*
```


## Networks

The BIND, DHCPD, and RAC containers communicate over a 10.10.10.0/24 network. This is known within the cluster as the public network.

Create the public virtual network.
```
docker network create --subnet=10.10.10.0/24 pub
```

The 11.11.11.0/24 network is known within the cluster as the private network. This will be used as the cluster interconnect. DHCPD will also serve IP addresses on this network.

Create the private virtual network.
```
docker network create --subnet=11.11.11.0/24 priv
```


## BIND
The BIND container will be used for DNS for the cluster.

Create the BIND container but don't start it until the networks have been added. Unless you need it, disable the administration GUI `--env WEBMIN_ENABLED=false`. The `-4` option prevents the named/bind process from listening on the IPV6 networks.
```
docker create \
--name bind \
--hostname bind \
--publish 53:53/tcp \
--publish 53:53/udp \
--volume /srv/docker/bind:/data \
--env WEBMIN_ENABLED=false \
sethmiller/bind \
-4
```

Connect the 10.10.10.0/24 network to the BIND container.
```
docker network connect --ip 10.10.10.10 pub bind
```

Start the BIND container.
```
docker start bind
```


## DHCPD
The DHCPD container will be used for generating IP addresses needed by the cluster nodes. It is also responsible for updating DNS with hostname IP pairs.

Create the configuration directory.
```
sudo mkdir -p /srv/docker/dhcpd
sudo chmod 777 /srv/docker/dhcpd
```

Copy the dhcpd.conf file to the configuration directory.
```
cp dhcpd.conf /srv/docker/dhcpd/
```

Create the DHCPD container but don't start it until the networks have been added.
```
docker create \
--name dhcpd \
--hostname dhcpd \
--volume /srv/docker/dhcpd:/data \
--volume /srv/docker/bind/bind/etc:/keys \
--dns 10.10.10.10 \
networkboot/dhcpd
```

Connect the pub and priv docker networks to the DHCPD container.
```
docker network connect --ip 10.10.10.11 pub dhcpd 
docker network connect --ip 11.11.11.11 priv dhcpd 
```

Start the DHCPD container.
```
docker start dhcpd
```


## NFS
The NFS server will share a host OS directory with the RAC node containers over NFS.

Create the configuration directory.
```
sudo mkdir -p /srv/docker/nfs
sudo chmod 777 /srv/docker/nfs
```

Copy the ganesha.conf file to the configuration directory.
```
cp ganesha.conf /srv/docker/nfs/
```

Create the NFS container.
```
docker run \
--detach \
--privileged \
--name nfs \
--hostname nfs \
--volume /srv/docker/nfs:/etc/ganesha \
--volume /oraclenfs:/oraclenfs \
--dns 10.10.10.10 \
sethmiller/nfs
```

Connect the pub docker network to the NFS container.
```
docker network connect --ip 10.10.10.12 pub nfs
```


## RAC Node Image
The RAC node container will be used for the grid infrastructure and database software. This process can be duplicated to create as many nodes as you want in your cluster.

Create a custom service and a scripts directory.
```
sudo mkdir -p /srv/docker/rac_nodes/custom_services
sudo mkdir -p /srv/docker/scripts

sudo chmod 777 /srv/docker/rac_nodes/custom_services
sudo chmod 777 /srv/docker/scripts
```

Copy the dhclient and network scripts from the repository to the custom service and scripts directories respectively.
```
cp dhclient-rac1-eth-pub.service /srv/docker/rac_nodes/custom_services/
cp dhclient-rac1-eth-priv.service /srv/docker/rac_nodes/custom_services/

cp networks-rac1.sh /srv/docker/scripts/
```

Create the RAC node container. The `/srv/docker/rac_nodes/custom_services` directory holds configuration files shared among all of the RAC node containers. The `/oracledata/stage` directory holds the Oracle installation files. The `/sys/fs/cgroup` directory is necessary for systemd to run in the containers. The grid installation will fail without at least 1.5GB of shared memory.
```
docker build --tag rac_initial ./Dockerfile-racnode

docker run \
--detach \
--privileged \
--name rac1 \
--hostname apprehensiveobserver0 \
--volume /srv/docker/rac_nodes/custom_services:/usr/lib/custom_services \
--volume /newdata:/stage \
--volume /sys/fs/cgroup:/sys/fs/cgroup:ro \
--shm-size 4096m \
--dns 10.10.10.10 \
rac_initial \
/usr/lib/systemd/systemd --system --unit=multi-user.target
```

Add the two custom networks to the RAC node container. I initially tried to use the `docker network connect` commands that were used for the DHCPD container but the name of the network adapter must be consistent in all the RAC node container and `docker network connect` does not allow you to specify an adapter name. I used to use a script called pipework but the results were inconsistent so I found the network namespace commands it was using and put them into individual scripts.

Unlike the native docker network functions, the virtual adapters are not deleted automatically when the container is removed. There can be consequences if you are recreating your RAC containers over and over again without deleting the virtual adapters so the `ip link delete` commands were added to the scripts to delete any previously existing virtual adapters before creating the new ones needed by the RAC node container.
```
sudo /srv/docker/scripts/networks-rac1.sh
```

Copy the udev configuration file from the repository for the ASM disks into the custom services directory.
```
cp 99-asm-disks.rules /srv/docker/rac_nodes/custom_services/
```

Link the udev configuration file to the udev rules.d directory in the RAC node container.
```
docker exec rac1 ln -s /usr/lib/custom_services/99-asm-disks.rules  /etc/udev/rules.d/
```

Tell udev to read the new rules configuration.
```
docker exec rac1 udevadm control --reload-rules
docker exec rac1 udevadm trigger
```

Now my ASM disk devices look like this in the RAC node container.
```
$ docker exec rac1 ls -l /dev/sd*
brw-rw---- 1 root disk     8,  0 May 30 13:24 /dev/sda
brw-rw---- 1 root disk     8,  1 May 30 13:24 /dev/sda1
brw-rw---- 1 root disk     8, 14 May 30 13:24 /dev/sda14
brw-rw---- 1 root disk     8, 15 May 30 13:24 /dev/sda15
brw-rw---- 1 grid asmadmin 8, 16 May 30 13:24 /dev/sdb
$ docker exec rac1 ls -ld /dev/asmdisks/
drwxr-xr-x. 2 root root 100 Oct 17 16:49 /dev/asmdisks/
$ docker exec rac1 ls -l /dev/asmdisks/
total 0
lrwxrwxrwx 1 root root 6 Jun  8 10:01 asm-clu-121-DATA-disk1 -> ../sdb
```

Connect to the RAC node container and execute the grid infrastructure installer. This will install the grid software only.

During the installation, you will see the message `Some of the optional prerequisites are not met`. This is normal and a consequence of running in a container.
```
docker exec rac1 su - grid -c ' \
/stage/12.1.0.2/grid/runInstaller -waitforcompletion \
-ignoreSysPrereqs -silent -force \
"INVENTORY_LOCATION=/u01/app/oraInventory" \
"UNIX_GROUP_NAME=oinstall" \
"ORACLE_HOME=/u01/app/12.1.0/grid" \
"ORACLE_BASE=/u01/app/grid" \
"oracle.install.option=CRS_SWONLY" \
"oracle.install.asm.OSDBA=asmdba" \
"oracle.install.asm.OSOPER=asmoper" \
"oracle.install.asm.OSASM=asmadmin"'
```

Run the two root scripts as root in the RAC node container.
```
docker exec rac1 /u01/app/oraInventory/orainstRoot.sh
docker exec rac1 /u01/app/12.1.0/grid/root.sh
```

Connect to the RAC node container and execute the database installer. This will install the database software only.

During the installation, you will see the message `Some of the optional prerequisites are not met`. This is normal and a consequence of running in a container.
```
docker exec rac1 su - oracle -c ' \
/stage/12.1.0.2/database/runInstaller -waitforcompletion \
-ignoreSysPrereqs -silent -force \
"oracle.install.option=INSTALL_DB_SWONLY" \
"INVENTORY_LOCATION=/u01/app/oraInventory" \
"UNIX_GROUP_NAME=oinstall" \
"ORACLE_HOME=/u01/app/oracle/product/12.1.0/dbhome_1" \
"ORACLE_BASE=/u01/app/oracle" \
"oracle.install.db.InstallEdition=EE" \
"oracle.install.db.DBA_GROUP=dba" \
"oracle.install.db.OPER_GROUP=oper" \
"oracle.install.db.BACKUPDBA_GROUP=backupdba" \
"oracle.install.db.DGDBA_GROUP=dgdba" \
"oracle.install.db.KMDBA_GROUP=kmdba" \
"DECLINE_SECURITY_UPDATES=true"'
```

Run the root script as root in the RAC node container.
```
docker exec rac1 /u01/app/oracle/product/12.1.0/dbhome_1/root.sh
```

Exit the RAC node container and create a new image which will be used as the base of any additional RAC node containers.
```
docker commit rac1 giinstalled
```

## First RAC Node Container (rac1)
Create a new RAC node container from the image you just created.
```
docker rm -f rac1

docker run \
--detach \
--privileged \
--name rac1 \
--hostname apprehensiveobserver0 \
--volume /srv/docker/rac_nodes/custom_services:/usr/lib/custom_services \
--volume /newdata:/stage \
--volume /sys/fs/cgroup:/sys/fs/cgroup:ro \
--shm-size 4096m \
--dns 10.10.10.10 \
giinstalled \
/usr/lib/systemd/systemd --system --unit=multi-user.target
```

Start the networks in the RAC node container as was done previously.
```
sudo /srv/docker/scripts/networks-rac1.sh
```

Configure the installed grid infrastructure.

During the configuration, you will see the message `Some of the optional prerequisites are not met`. This is normal and a consequence of running in a container.
```
docker exec rac1 su - grid -c ' \
/u01/app/12.1.0/grid/crs/config/config.sh -waitforcompletion \
-ignoreSysPrereqs -silent \
"INVENTORY_LOCATION=/u01/app/oraInventory" \
"oracle.install.option=CRS_CONFIG" \
"ORACLE_BASE=/u01/app/grid" \
"ORACLE_HOME=/u01/app/12.1.0/grid" \
"oracle.install.asm.OSDBA=asmdba" \
"oracle.install.asm.OSOPER=asmoper" \
"oracle.install.asm.OSASM=asmadmin" \
"oracle.install.crs.config.gpnp.scanName=clu-121-scan.clu-121.example.com" \
"oracle.install.crs.config.gpnp.scanPort=1521 " \
"oracle.install.crs.config.ClusterType=STANDARD" \
"oracle.install.crs.config.clusterName=clu-121" \
"oracle.install.crs.config.gpnp.configureGNS=true" \
"oracle.install.crs.config.autoConfigureClusterNodeVIP=true" \
"oracle.install.crs.config.gpnp.gnsOption=CREATE_NEW_GNS" \
"oracle.install.crs.config.gpnp.gnsSubDomain=clu-121.example.com" \
"oracle.install.crs.config.gpnp.gnsVIPAddress=clu-121-gns.example.com" \
"oracle.install.crs.config.clusterNodes=apprehensiveobserver0:AUTO" \
"oracle.install.crs.config.networkInterfaceList=eth-pub:10.10.10.0:1,eth-priv:11.11.11.0:2" \
"oracle.install.crs.config.storageOption=LOCAL_ASM_STORAGE" \
"oracle.install.crs.config.useIPMI=false" \
"oracle.install.asm.SYSASMPassword=oracle_4U" \
"oracle.install.asm.monitorPassword=oracle_4U" \
"oracle.install.asm.diskGroup.name=DATA" \
"oracle.install.asm.diskGroup.redundancy=EXTERNAL" \
"oracle.install.asm.diskGroup.disks=/dev/asmdisks/asm1" \
"oracle.install.asm.diskGroup.diskDiscoveryString=/dev/asmdisks/*,/oraclenfs/asm*" \
"oracle.install.asm.useExistingDiskGroup=false"'
```

Run the root script as the root user.
```
docker exec rac1 /u01/app/12.1.0/grid/root.sh
```

Copy the tools configuration assistant response file from the repository to the custom services directory. Change the passwords in the file if necessary before copying. To save on resources and time, the response file is configured to not install the management database (GIMR). If you want to install the GIMR, remove the last three lines of the response file.
```
cp tools_config.rsp /srv/docker/rac_nodes/custom_services/
```

Run the tools configuration assistant.
```
docker exec rac1 su - grid -c '/u01/app/12.1.0/grid/cfgtoollogs/configToolAllCommands \
RESPONSE_FILE=/usr/lib/custom_services/tools_config.rsp'
```

Delete the tools configuration assistant response file.
```
rm -f /srv/docker/rac_nodes/custom_services/tools_config.rsp
```

Since the cluster was not active when the database binaries were installed, the database installation was not enabled for RAC. This step recompiles the `oracle` executable for RAC.
```
docker exec rac1 su - oracle -c 'export ORACLE_HOME=/u01/app/oracle/product/12.1.0/dbhome_1 && \
make -f $ORACLE_HOME/rdbms/lib/ins_rdbms.mk rac_on && \
make -f $ORACLE_HOME/rdbms/lib/ins_rdbms.mk ioracle'
```


## Second RAC Node Container (rac2)
Create a second RAC node container.
```
docker run \
--detach \
--privileged \
--name rac2 \
--hostname apprehensiveobserver1 \
--volume /srv/docker/rac_nodes/custom_services:/usr/lib/custom_services \
--volume /newdata:/stage \
--volume /sys/fs/cgroup:/sys/fs/cgroup:ro \
--shm-size 4096m \
--dns 10.10.10.10 \
giinstalled \
/usr/lib/systemd/systemd --system --unit=multi-user.target
```

Copy the dhclient and network scripts from the repository to the custom service and scripts directories respectively.
```
cp dhclient-rac2-eth-pub.service /srv/docker/rac_nodes/custom_services/
cp dhclient-rac2-eth-priv.service /srv/docker/rac_nodes/custom_services/

cp networks-rac2.sh /srv/docker/scripts/
```

Start the networks in the RAC node container.
```
sudo /srv/docker/scripts/networks-rac2.sh
```

Configure the grid infrastructure installation to join the existing cluster. Keep in mind that these commands must be executed on a node already part of the cluster (rac1).
```
docker exec rac1 su - grid -c '/u01/app/12.1.0/grid/addnode/addnode.sh \
"CLUSTER_NEW_NODES={apprehensiveobserver1}" "CLUSTER_NEW_VIRTUAL_HOSTNAMES={apprehensiveobserver1-vip}" \
-waitforcompletion -silent -ignoreSysPrereqs -force -noCopy'
```

Run the root script as the root user.
```
docker exec rac2 /u01/app/12.1.0/grid/root.sh
```

Recompile the `oracle` executable for RAC.
```
docker exec rac2 su - oracle -c 'export ORACLE_HOME=/u01/app/oracle/product/12.1.0/dbhome_1 && \
make -f $ORACLE_HOME/rdbms/lib/ins_rdbms.mk rac_on && \
make -f $ORACLE_HOME/rdbms/lib/ins_rdbms.mk ioracle'
```


## Optional Tasks

Create a database.
```
docker exec rac1 su - oracle -c ' \
/u01/app/oracle/product/12.1.0/dbhome_1/bin/dbca -createDatabase -silent \
-templateName General_Purpose.dbc \
-gdbName apprehensiveobserver \
-sysPassword oracle_4U \
-systemPassword oracle_4U \
-storageType ASM \
-diskGroupName DATA \
-recoveryGroupName DATA \
-characterSet AL32UTF8 \
-nationalCharacterSet UTF8 \
-totalMemory 1024 \
-emConfiguration none \
-nodelist apprehensiveobserver0,apprehensiveobserver1 \
-createAsContainerDatabase True'
```

Create the NDATA ASM disk group.
```
cp oraclenfs.mount /srv/docker/rac_nodes/custom_services/

docker exec rac1 ln -s /usr/lib/custom_services/oraclenfs.mount /etc/systemd/system/
docker exec rac2 ln -s /usr/lib/custom_services/oraclenfs.mount /etc/systemd/system/

docker exec rac1 systemctl daemon-reload
docker exec rac2 systemctl daemon-reload

docker exec rac1 systemctl start oraclenfs.mount
docker exec rac2 systemctl start oraclenfs.mount

docker exec rac1 su - grid -c "ORACLE_SID=+ASM1 /u01/app/12.1.0/grid/bin/asmca \
-silent -createDiskGroup \
-diskGroupName NDATA \
-redundancy EXTERNAL \
-disk '/oraclenfs/asm-clu-121-NDATA-disk1' \
-disk '/oraclenfs/asm-clu-121-NDATA-disk2' \
-disk '/oraclenfs/asm-clu-121-NDATA-disk3'"

  <dg name=\"NDATA\" redundancy=\"external\"> \
  <dsk string=\"/oraclenfs/asm-clu-121-NDATA-disk1\"/> \
  <dsk string=\"/oraclenfs/asm-clu-121-NDATA-disk2\"/> \
  <dsk string=\"/oraclenfs/asm-clu-121-NDATA-disk3\"/> \
</dg>'"
```   

Confirm the clusterware resources are running.
```
docker exec rac1 /u01/app/12.1.0/grid/bin/crsctl status resource -t
```

***
If the ASM disks have existing headers that you want to clear, use dd to wipe out the headers.
!!!WARNING!!! This will destroy these disks and anything on them. Make sure you are clearing the right disks.
```
for i in sdd sde sdf; do
  sudo dd if=/dev/zero of=/dev/$i bs=100M count=1
done
```
