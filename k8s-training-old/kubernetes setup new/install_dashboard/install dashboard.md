## install helm client on local
ref : https://helm.sh/docs/intro/install/

download > https://get.helm.sh/helm-v3.15.0-windows-amd64.zip


## install kubernetes dashboard
ref : https://github.com/kubernetes/dashboard

### Add kubernetes-dashboard repository
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
### Deploy a Helm Release named "kubernetes-dashboard" using the kubernetes-dashboard chart
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard

helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard -f install_dashboard/dashboard-config.yaml

helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard --set=app.ingress.hosts=[0.0.0.0]

### change kubernetes-dashboard-kong-proxy from ClusterIP to NodePort
kubectl patch svc kubernetes-dashboard-kong-proxy --type=merge -p "{\"spec\":{\"type\" : \"NodePort\" }}" -n kubernetes-dashboard

### check service kubernetes dashboard and find kubernetes-dashboard-kong-proxy and get port mapping 443 for use access dashboard like https://kubemaster1:30964
kubectl -n kubernetes-dashboard get svc

## create admin user
kubectl apply -f install_dashboard/dashboard-adminuser.yaml

### show token admin-user
kubectl -n kubernetes-dashboard create token admin-user

kubectl -n default create token admin-user

<SERVICE_ACCOUNT_TOKEN_REDACTED>




### if want to see service config yaml format
kubectl get svc kubernetes-dashboard-kong-proxy -o yaml -n kubernetes-dashboard


# remove dashboard 
## how to remove dashboard
helm delete kubernetes-dashboard --namespace kubernetes-dashboard

## how to remove admin-user
kubectl -n kubernetes-dashboard delete serviceaccount admin-user
kubectl -n kubernetes-dashboard delete clusterrolebinding admin-user

kubectl delete namespace kubernetes-dashboard


kubectl -n kubernetes-dashboard get serviceaccount
kubectl -n kubernetes-dashboard get clusterrolebinding


helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard

kubectl apply -f install_dashboard/dashboard-user.yaml

kubectl apply -f install_dashboard/dashboard-clusterrolebinding.yaml

kubectl apply -f install_dashboard/dashboard-secret.yaml

kubectl get secret $(kubectl get serviceaccount dashboard-user -o jsonpath="{.secrets[0].name}" -n kubernetes-dashboard) -o jsonpath="{.data.token}" | base64 --decode

kubectl get secret dashboard-user -n kubernetes-dashboard -o jsonpath="{.data.token}" | base64 --decode

<SERVICE_ACCOUNT_TOKEN_REDACTED>
