---
title: Kubernetes and Calico In GNS3
date: 2017-12-12T07:50:38Z
---

Designing an on-premise Kubernetes cluster can be quite a challenge, especially as it needs to fit
into the existing network topology. There are plenty of 
[CNI plugins](https://kubernetes.io/docs/concepts/cluster-administration/network-plugins/#cni)
available for the job and they might support different modes and topologies. To get familiar with
them, one might need a testing environment and the 
[minikube](https://github.com/kubernetes/minikube#what-is-minikube) won't suffice anymore. You 
might choose to run Kube nodes as multiple VMs, perhaps using Vagrant, but how to simulate the 
physical network they are plugged into?

GNS3 is a network simulator well known to the networking folks as they use it to simulate their 
complex environments full of Cisco boxes. But GNS3 is actually very versatile, it can run Qemu VMs
and even docker containers that we can connect using virtual ethernet cables and organize in neat
network diagrams. Fully working, 4 nodes Kubernetes cluster connected to a "complex" virtual 
network might look like this in GNS3:

![Kubernetes Topology example](/pictures/topology_example.png)

Let's see how to build a cluster like this on a Linux worstation, using 
[Calico](https://www.projectcalico.org/) as the networking solution.

### Installing prerequisites

First, we need to install GNS3, docker and qemu and bridge-utils. Follow the official installation
guides, or run following (works on Ubuntu 17.10):

```shell
sudo add-apt-repository ppa:gns3/unstable
curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu artful stable"
sudo apt-get update
sudo apt-get install gns3-gui docker-ce qemu-utils bridge-utils

# verify docker is running:
sudo docker run hello-world
```

Also, we want to connect our GNS3 virtual environment to the host machine, so that we can reach our
Kubernetes cluster over the network and the machines in the cluster can reach Internet. For this,
we create and configure a bridge interface gnsbr0 and dedicate a subnet range to our project:

```shell
brctl addbr gnsbr0
ip addr add 172.31.0.1/24 dev gnsbr0
ip link set up dev gnsbr0
iptables -t nat -A POSTROUTING -s 172.31.0.0/16 -j MASQUERADE
ip route add 172.31.0.0/16 via 172.31.0.2
```

### Prepare GNS3 project

Now let's start GNS3. A dialog appears asking us to create a new project. Let's do just that and
call our project 'kubernetes'.

Before we start creating our infrastructure, we need to create two appliance templates. First, we
add a lightweight router to simulate network devices. Click on "New appliance template" and choose
"Add a Docker container".

![New Appliance Template](/pictures/new_appliance_template.png)

Select New Image and type `wigwam/bird`. Name it `bird-docker`. Give it 3 adapters and then keep
defaults all the way to Finish. The new device should appear in the left panel. Right-click on it
and choose Configure Template. Change category to router and the symbol to the router icon.

Download a Ubuntu image from [here](https://github.com/tomas-mazak/ubuntu-qemu/releases/latest) 
and unpack it. Create a new appliance template, this time select "Add a Qemu virtual machine". 
Name it `ubuntu`, give it 1200MB RAM and choose "New Image" and select the downloaded Ubuntu image 
and Finish. Right-click on it and choose "Configure Template". Change the symbol to the server 
icon.

You can customize and build both images yourself, just clone these repos:

  * https://github.com/tomas-mazak/bird-docker
  * https://github.com/tomas-mazak/ubuntu-qemu 

...and follow the instructions.

### Set up the topology

Now that we have appliance templates ready, let's start creating network for our cluster. We 
simulate two separate L3 subnets several hops from each other.

Let's drag a `bird-docker` template to the workspace. Name it `spine`. Right-click it and choose 
Configure. Click Network configuration - Edit. Paste the following:

```
auto eth0
iface eth0 inet static
    address 172.31.0.2
    netmask 255.255.255.0
    gateway 172.31.0.1
 
auto eth1
iface eth1 inet static
    address 172.31.1.1
    netmask 255.255.255.0
    up echo 'protocol bgp leaf1 { local as 65000; neighbor 172.31.1.2 as 65001; import all; export all; }' > /etc/bird/eth1-peer.conf
 
auto eth2
iface eth2 inet static
    address 172.31.2.1
    netmask 255.255.255.0
    up echo 'protocol bgp leaf2 { local as 65000; neighbor 172.31.2.2 as 65002; import all; export all; }' > /etc/bird/eth2-peer.conf
```

Now drag Cloud to the workspace and name it uplink. Click Add a link icon and drag from cloud 
(choose `gnsbr0` interface) to spine router (`eth0` interface). Click the green arrow to start 
devices. Now the workspace should look like this:

![First Router](/pictures/first_router.png)

Let's verify we can ping the router from the host machine:
```
$ ping 172.31.0.2
PING 172.31.0.2 (172.31.0.2) 56(84) bytes of data.
64 bytes from 172.31.0.2: icmp_seq=1 ttl=64 time=0.363 ms
64 bytes from 172.31.0.2: icmp_seq=2 ttl=64 time=0.279 ms
^C
--- 172.31.0.2 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 999ms
rtt min/avg/max/mdev = 0.279/0.321/0.363/0.042 ms
```

Now, let's add two more routers, `leaf1` and `leaf2`. Connect their `eth0` interfaces to spine 
`eth1` and `eth2`. Set leaf1 configuration:

```
auto eth0
iface eth0 inet static
    address 172.31.1.2
    netmask 255.255.255.0
    up echo 'protocol bgp spine { local as 65001; neighbor 172.31.1.1 as 65000; import all; export all; }' > /etc/bird/eth0-peer.conf
 
auto br0
iface br0 inet static
    bridge-ports eth1 eth2
    bridge-stp 0
    address 172.31.3.1
    netmask 255.255.255.0
    pre-up brctl addbr br0
 
auto eth1
iface eth1 inet manual
    up ip link set $IFACE up
    up brctl addif br0 $IFACE
 
auto eth2
iface eth2 inet manual
    up ip link set $IFACE up
    up brctl addif br0 $IFACE
```

And leaf2 configuration:
```
auto eth0
iface eth0 inet static
    address 172.31.2.2
    netmask 255.255.255.0
    up echo 'protocol bgp spine { local as 65002; neighbor 172.31.2.1 as 65000; import all; export all; }' > /etc/bird/eth0-peer.conf
 
auto br0
iface br0 inet static
    bridge-ports eth1 eth2
    bridge-stp 0
    address 172.31.4.1
    netmask 255.255.255.0
    pre-up brctl addbr br0
 
auto eth1
iface eth1 inet manual
    up ip link set $IFACE up
    up brctl addif br0 $IFACE
 
auto eth2
iface eth2 inet manual
    up ip link set $IFACE up
    up brctl addif br0 $IFACE
```

Now, let's add 4 ubuntu servers and name them kube-node1-4. We connect 2 servers to each leaf 
router. Right click kube-node1, select Configure and change RAM to 1700 MB. Press green arrow once
again and the topology should look like this:
![First Topology](/pictures/first_topology.png)

Now we need to log in to all nodes and setup networking so we can reach the nodes remotely 
(annoying, I know). Double click the server icon and log in as root with password `gns3`:
```
root@ubuntu:~# hostname kube-node1
root@ubuntu:~# echo kube-node1 > /etc/hostname
root@ubuntu:~# cat > /etc/network/interfaces
auto lo
iface lo inet loopback
 
auto ens3
iface ens3 inet static
    address 172.31.3.11
    netmask 255.255.255.0
    gateway 172.31.3.1
    up echo 'nameserver 8.8.8.8' > /etc/resolv.conf
root@ubuntu:~# systemctl restart networking
root@ubuntu:~# apt-get update # to test connectivity
 
# Change hostname/IP/gateway for each node.
# kube-node3,4 will be in subnet https://www.linkedin.com/redir/invalid-link-page?url=172%2e31%2e4%2e0%2F24%2e
```
 
Now we should be able to ssh to the servers from the host machine. Let's copy ssh keys to them to
make this easier (if you don't have one, generate one using ssh-keygen command):

```
# password is 'gns3'
tomas@arkham:~$ ssh-copy-id root@172.31.3.11
tomas@arkham:~$ ssh-copy-id root@172.31.3.12
tomas@arkham:~$ ssh-copy-id root@172.31.4.11
tomas@arkham:~$ ssh-copy-id root@172.31.4.12
```

### Install Kubernetes

We will install a simple kubernetes cluster with one master using 
[kubespray](https://github.com/kubernetes-incubator/kubespray). Let's prepare the environment 
(might differ if you don't use Ubuntu):

```
$ sudo apt-get install virtualenvwrapper
$ mkvirtualenv kubespray
(kubespray) $ pip install ansible netaddr
(kubespray) $ git clone https://github.com/kubernetes-incubator/kubespray.git
(kubespray) $ cd kubespray/
```
 
Now we need to prepare inventory file. Save following as `inventory/inventory.cfg`:

```dosini
[all]
kube-node1      ansible_host=172.31.3.11 ip=172.31.3.11
kube-node2      ansible_host=172.31.3.12 ip=172.31.3.12
kube-node3      ansible_host=172.31.4.11 ip=172.31.4.11
kube-node4      ansible_host=172.31.4.12 ip=172.31.4.12
 
[kube-master]
kube-node1    
 
[kube-node]
kube-node1    
kube-node2    
kube-node3    
kube-node4    
 
[etcd]
kube-node1    
kube-node2    
kube-node3    
 
[k8s-cluster:children]
kube-node    
kube-master    
 
[calico-rr]
 
[vault]
kube-node1    
kube-node2    
kube-node3
```
 
Open inventory/group_vars/k8s-cluster.yml and set:

```
enable_network_policy: true
kube_service_addresses: 172.31.64.0/18
kube_pods_subnet: 172.31.128.0/18
```

Now we are ready to run ansible to deploy the cluster:

```
(kubespray) $ ansible-playbook -i inventory/inventory.cfg cluster.yml -b -v -u root
```

Yeey, cluster up and running! If you find a mistake in this blog, kindly 
[raise an issue](https://github.com/tomas-mazak/containerd.eu/issues).

In the next blog, I will look into BGP peering between Kubernetes nodes (using Calico) and 
"physical" routers, using popular 
[AS-per-rack](https://docs.projectcalico.org/v2.6/reference/private-cloud/l3-interconnect-fabric#the-as-per-rack-model) 
topology.
