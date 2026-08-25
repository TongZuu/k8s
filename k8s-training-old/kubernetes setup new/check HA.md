ip address del 192.168.50.179/24 dev ens192

ip -br a


kubectl get pod -A
etcd-kubemaster1


kubectl logs --tail=1000 keepalived-kubemaster1 -n kube-system

kubectl logs --tail=1000 haproxy-kubemaster1 -n kube-system

kubectl delete -n kube-system pods haproxy-kubemaster1

kubectl delete -n kube-system pods keepalived-kubemaster1

kubectl exec --stdin --tty -n kube-system keepalived-kubemaster1 -- /bin/bash




curl -i -v controlplane:7443

kubectl logs --tail=1000 kube-apiserver-kubemaster2 -n kube-system

kubectl logs --tail=1000 keepalived-kubemaster2 -n kube-system

kubectl logs --tail=1000 haproxy-kubemaster2 -n kube-system

kubectl delete -n kube-system pods haproxy-kubemaster2

kubectl delete -n kube-system pods keepalived-kubemaster2

kubectl exec --stdin --tty -n kube-system keepalived-kubemaster2 -- /bin/bash