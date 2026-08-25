v-IP 192.168.40.35
Master
- zeeme-Kuberneter-master01     IP 192.168.40.32  โต้ง
- zeeme-kubernetes-master02     IP 192.168.40.33  พัส
- zeeme-kubernetes-master03     IP 192.168.40.34 เทป
Worker
- zeeme-kubernetes-node1    IP 192.168.30.145   กอล์ฟ
- zeeme-kubernetes-node2    IP 192.168.30.149   แบงค์  
- zeeme-kubernetes208_new   IP 192.168.40.30     พี
- zeeme-kubernetes209_new   IP 192.168.40.31    แคท

192.168.30.207  registry.myhr.co.th     registry
192.168.40.32  zeeme-Kubernetes-master01     master01
192.168.40.33  zeeme-Kubernetes-master02     master02
192.168.40.34  zeeme-Kubernetes-master03     master03
192.168.30.145  zeeme-kubernetes-node1     kubenode1
192.168.30.149  zeeme-kubernetes-node2     kubenode2
192.168.40.30   zeeme-kubernetes-node3     kubenode3
192.168.40.31   zeeme-kubernetes-node4     kubenode4
192.168.40.35  zeeme-keepalived-vir     keepalived-vir


Trainning Zeeme Master 01 [192.168.50.180]
Trainning Zeeme Master 02 [192.168.50.181]
Trainning Zeeme Worker 01 [192.168.50.182]
Trainning Zeeme Worker 02 [192.168.50.183]
user VPN (FortiClient) : it.admin  pass :  <VPN_PASSWORD> 
user login : root   pass : <ROOT_PASSWORD>



keepAlive 	-> Manage Virtual IP
HAProxy	-> Loadbalance
hlem		-> เป็นตัวช่วยในการ install




 mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

Alternatively, if you are the root user, you can run:

  export KUBECONFIG=/etc/kubernetes/admin.conf

You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/

You can now join any number of the control-plane node running the following command on each as root:

  kubeadm join keepalived-vir:80 --token <BOOTSTRAP_TOKEN> \
	--discovery-token-ca-cert-hash sha256:<CA_CERT_HASH> \
	--control-plane --certificate-key <CERTIFICATE_KEY>

Please note that the certificate-key gives access to cluster sensitive data, keep it secret!
As a safeguard, uploaded-certs will be deleted in two hours; If necessary, you can use
"kubeadm init phase upload-certs --upload-certs" to reload certs afterward.

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join keepalived-vir:80 --token <BOOTSTRAP_TOKEN> \
	--discovery-token-ca-cert-hash sha256:<CA_CERT_HASH> 
