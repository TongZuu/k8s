## run service for test
kubectl apply -f https://k8s.io/examples/application/php-apache.yaml


## set auto scale
kubectl autoscale deployment php-apache --cpu-percent=40 --min=1 --max=10



## test call api for test auto scale
kubectl run -i --tty load-generator --rm --image=busybox:1.28 --restart=Never -- /bin/sh -c "while sleep 0.01; do wget -q -O- http://php-apache; done"
