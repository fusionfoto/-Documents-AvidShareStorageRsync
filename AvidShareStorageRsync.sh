#!/bin/sh
PATH="/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin/"

# Lets load our configuration file.
source ./AvidShareStorageRsync.conf

getAuthToken(){
	PAYLOAD="curl -I -X GET $api_authURL -H 'x-auth-key: '"${api_key}"'' -H 'x-auth-user: '"${api_user}"'' > .authFile"
	echo "Ran: "$PAYLOAD
	curl -I -X GET $api_authURL -H 'x-auth-key: '"${api_key}"'' -H 'x-auth-user: '"${api_user}"'' > .authFile
	api_storageURL=$( cat .authFile | grep X-Storage-Url: | awk '{print $2}' | tr -d '\r' )
	api_authToken=$( cat .authFile | grep X-Storage-Token: | awk '{print $2}' | tr -d '\r' )
	echo $api_storageURL
	echo $api_authToken
}
rawurlencode() {
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o

  for (( pos=0 ; pos<strlen ; pos++ )); do
     c=${string:$pos:1}
     case "$c" in
        [-_.~a-zA-Z0-9] ) o="${c}" ;;
        * )               printf -v o '%%%02x' "'$c"
     esac
     encoded+="${o}"
  done
  echo "${encoded}"
}
rsync_volume () {
	echo "============================ Loop per volume in array"
	echo "mkdir /Volumes/$1" ## Create mountpoint
	echo "/usr/local/bin/mount_avid -U $ISIS_username:$ISIS_password -g $ISIS_workgroup $ISIS_virtualName:$1 /Volumes/$1" ## Mount ISIS/NEXIS volume
	echo "Running Rsync from /Volumes/$1 to /Volumes/$smb_volume/$1/"
	echo "checking for /Volumes/$smb_volume/$1/.logs/"
	if [ ! -d /Volumes/$smb_volume/$1/.logs/ ]; then
		echo "creating.. /Volumes/$smb_volume/$1/.logs/"
		mkdir /Volumes/$smb_volume/$1
		mkdir /Volumes/$smb_volume/$1/.logs/
	fi
	logFile="/Volumes/$smb_volume/$1/.logs/$1_$(date +%Y%m%d%H%M%S).log"
	rsync -aru --log-file=$logFile --exclude=.* --backup-dir=/Volumes/$1/.backups/ --suffix=$(date +"%Y%m%d%H%M") --block-size=$smb_blockSize /Volumes/$1/ /Volumes/$smb_volume/$1
	metadata_updator $logFile /Volumes/$smb_volume/ $1 ## Run Metadata extractor against log file

	if [[ ${AvidProjectVolumes[@]} =~ $1 ]]; then
		## Here, you can run extra logic to handle volumes with Projects files. You can handle Unity Attic archive and cleanup (Speeds up Media Composer Saving time) 
		echo "Running extra logic for project volumes"
		echo "find /Volumes/$1 -type d -empty -delete"
	fi
	echo "mount -f /Volumes/$1"
}
varifyBaseOnPMR (){
	basePath=$(dirname "${1}")
	path=$( echo "${basePath}" | sed 's/ /\\ /g')
	
	echo "strings -n 10 \"$1\" > \"$basePath/.pmr\""
	strings -n 10 "$1" > "$basePath/.pmr"
	while read mediaFile; do
		echo "Check if $basePath/$mediaFile exist"
		if [ ! -f "$basePath/$mediaFile" ]; then
			echo "REPORT that we are missing this file $path/$mediaFile based on the PMR file"
		fi
	done<"$basePath/.pmr"
}
metadata_updator (){
	echo "expose embedded metadata from media (files in $1) using mediainfo and POST metadata to object via API"
	while read file; do
		line=$( echo $file | awk '{print $5,$6}' )

		if [[ $line == *mxf ]]; then
			path=$( echo $2$3/$line | sed 's/ /\\ /g')
			urlPath=$( echo $line | sed 's/ /\%20/g')
			elasticString=$(basename "${path}" | sed 's/\,//g') ## Need to remove ',' for elastic.
			swiftAPISTring=$( echo $line | sed 's/ /\%20/g')
			jsonResult=$( eval ffprobe -v quiet -print_format json -show_format -show_streams -i $path)
			fileSize=$(du "$2$3/$line" | awk '{print $1}')
			md5=$(md5 "$2$3/$line")
			jsonToString=$( echo  $jsonResult | jq -c '{ filesize_bytes: '"${fileSize}"',
				md5: "'"${md5}"'",
				height: .streams[0].height, 
				width: .streams[0].width, 
				codec_long_name: .streams[0].codec_long_name,
				color_space: .streams[0].color_space,
				pix_fmt: .streams[0].pix_fmt,
				avg_frame_rate: .streams[0].avg_frame_rate,
				duration: .streams[0].duration,
				Project: .format.tags.project_name,
				avid_uid: .format.tags.uid,
				clipname: .format.tags.material_package_name,
				fullFormat: .format
			  }' |  jq --arg foo bar '. + { "SwiftStack": "'"$api_storageURL"'/'"${line}"'" }' )
			# POST an update to object URL via API with $jsonToString value and also to Elastic to manually generate the index data.
			RESULT=$( curl --silent --output -X POST $elasticURL/$elasticIndex/metadata/${elasticString} -H 'content-type: application/json' -d "$jsonToString" )
			if [[ $(echo $RESULT | jq '.result') == "\"updated\"" ]]; then
				echo "Elastic Sync for $elasticURL/$elasticIndex/metadata/${elasticString} updated!"
			elif [[ $(echo $RESULT | jq '.result') == "\"created\"" ]]; then
				echo "Elastic Sync for $elasticURL/$elasticIndex/metadata/${elasticString} success!"
			else
				echo "Elastic Sync for $elasticURL/$elasticIndex/metadata/${elasticString} failed!"
				echo $RESULT
			fi
			SWIFT_RESULT=$(curl -s -i $api_storageURL/$3/$swiftAPISTring -X POST -H "X-Auth-Token: $api_authToken" -H "X-Object-Meta-Avid: $(echo $jsonToString | jq -c '.' ) ")
			curl -I $api_storageURL/$3/$swiftAPISTring -H "X-Auth-Token: $api_authToken"
		elif [[ $line == *pmr ]]; then

			varifyBaseOnPMR "$2$3/$line"
		else
			echo "Skipping..."
		fi
	done <$1
}

getAuthToken # Init API SwiftStack API variables
echo "mount -f /Volumes/$smb_volume"
for volume in ${AvidMediaVolumes[@]}
do
	if [ -z "$volume" ]; then
	   	exit 1
	else
		rsync_volume $volume
	fi 
done
echo "umount -f /Volumes/$smb_volume"
exit 0