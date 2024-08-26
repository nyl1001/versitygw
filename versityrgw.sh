#!/bin/bash

    	#ghcr.io/versity/versitygw:v1.0.5 --s3-iam-access E8QI6W804K3O6G4N9H3B --s3-iam-secret BCgBavhjBGnr3tnJhSZkdr7Oz62AFbiZ69B3WKFD --s3-iam-bucket versitygw --s3-iam-endpoint http://rgw.wanjiedata.com --s3-iam-noverify  --port :80 --admin-port :8080 posix /data
start_versitygw() {
    docker run -d --net host -v /cephfs_data:/data -v /apps/versitygw/iam:/iam -v /etc/localtime:/etc/localtime:ro \
    	--restart unless-stopped --name versitygw  \
    	-e ROOT_ACCESS_KEY="E8QI6W804K3O6G4N9H3B" -e ROOT_SECRET_KEY="BCgBavhjBGnr3tnJhSZkdr7Oz62AFbiZ69B3WKFD" \
    	hub.wanjiedata.com/library/versitygw:v1.0.5 --iam-dir /iam  --port :80 --admin-port :8080 posix /data

}

stop_versitygw() {
   docker rm -f versitygw
}

case $1 in
    start)
      start_versitygw
      ;;
    stop)
      stop_versitygw
      ;;
esac