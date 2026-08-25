firewall-cmd --permanent --add-port=10250/tcp
firewall-cmd --permanent --add-port=10256/tcp
firewall-cmd --permanent --add-port=30000-32767/tcp
firewall-cmd --reload