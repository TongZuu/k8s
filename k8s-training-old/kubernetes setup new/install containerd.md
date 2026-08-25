## copy file for install to /opt
1. containerd-1.7.16-linux-amd64.tar.gz
2. containerd.service
3. runc.amd64
4. cni-plugins-linux-amd64-v1.4.1.tgz


## install containerd reference
https://github.com/containerd/containerd/blob/main/docs/getting-started.md


### install containerd
#### extract it under /usr/local
cd /opt
tar Cxzvf /usr/local containerd-1.7.16-linux-amd64.tar.gz

### install containerd.service
#### move file containerd.service to /usr/local/lib/systemd/system/containerd.service and run command below
mkdir -p /usr/local/lib/systemd/system/
cp containerd.service /usr/local/lib/systemd/system/

systemctl daemon-reload
systemctl enable --now containerd

### install runc
#### install runc to /usr/local/sbin/runc
install -m 755 runc.amd64 /usr/local/sbin/runc


### install CNI plugin 
#### extract cni-plugins-linux-amd64-v1.4.1.tgz to /opt/cni/bin
mkdir -p /opt/cni/bin
tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.4.1.tgz
