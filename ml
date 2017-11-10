#!/bin/bash
ml_path=./
ec2_spotter_path=~/Documents/projects/automationWorkflow/ec2-spotter/
config_directory=~/
config_filename=.mlconfig
config_path="$config_directory$config_filename"

volume_size=32
name=ml_auto
ec2spotter_instance_type=p2.xlarge
bid_price=0.5
key_name=aws-key-$name

instance_domain_name=dev.aws
dns_file_path="/private/etc/hosts"
persistent_volume_size=100 # Go
persistent_mount_device="/dev/xvdh"
persistent_mount_point="/home/ubuntu/persist"

availability_zone="eu-west-1c"

if [ ! -e "$config_path" ] ; then
    configfile_secured='/tmp/cool.cfg'

    # check if the file contains something we don't want
    if egrep -q -v '^#|^[^ ]*=[^;]*' "$config_path"; then
      echo "Config file is unclean, cleaning it..." >&2
      # filter the original to a new file
      egrep '^#|^[^ ]*=[^;&]*'  "$config_path" > "$configfile_secured"
    fi

    . "$configfile_secured"
else
    source $config_path
fi

command=$1

# Read the input args
while [[ $# -gt 0 ]]
do
key="$1"
case $key in
    --ami)
    ami="$2"
    shift # pass argument
    ;;
    --subnetId)
    subnetId="$2"
    shift # pass argument
    ;;
    --securityGroupId)
    securityGroupId="$2"
    shift # pass argument
    ;;
    --volume_size)
    volume_size="$2"
    shift # pass argument
    ;;
    --key_name)
    key_name="$2"
    shift # pass argument
    ;;
    --ec2spotter_instance_type)
    ec2spotter_instance_type="$2"
    shift # pass argument
    ;;
    --bid_price)
    bid_price="$2"
    shift # pass argument
    ;;
    --instance_domain_name)
    instance_domain_name="$2"
    shift # pass argument
    ;;
    --persistent_volume_size)
    persistent_volume_size="$2"
    shift # pass argument
    ;;
    --persistent_mount_device)
    persistent_mount_device="$2"
    shift # pass argument
    ;;
    --persistent_mount_point)
    persistent_mount_point="$2"
    shift # pass argument
    ;;
    *)
            # unknown option
    ;;
esac
shift # pass argument or value
done

function set_config(){
    if grep -Fq "$1=" $config_path
    then
        sed -i.bak "s/^\($1\s*=\s*\).*\$/\1$2/" $config_path
    else
        echo "$1=$2" >> $config_path
    fi
}

if [ "$command" == "config" ]; then
    echo "# config stored in $config_path"
    cat $config_path
elif [ "$command" == "create_volume" ]; then
    export persistent_volume_id=`aws ec2 create-volume --availability-zone $availability_zone --size $persistent_volume_size --volume-type gp2 --output text --query 'VolumeId'`
    echo "persistent_volume_id $persistent_volume_id containing $persistent_volume_size"
    set_config persistent_volume_id $persistent_volume_id
elif [ "$command" == "set_ssh_config" ]; then
    echo "Host dev.aws" >> ~/.ssh/config
    echo "   StrictHostKeyChecking no" >> ~/.ssh/config
    echo "   UserKnownHostsFile=/dev/null" >> ~/.ssh/config
elif [ "$command" == "set_dns_config" ]; then
    echo "Will modify $dns_file_path..."
    sed -i.bak "/$instance_domain_name/s/.*/$instance_ip     $instance_domain_name/" $dns_file_path
    echo "Result:"
    cat $dns_file_path
elif [ "$command" == "terminate" ]; then
    if [ "$instance_id" == "" ]; then
        echo "ml doesn't know about any running instance."
        echo "Here is the state of instances: aws ec2 describe-instance-status"
        aws ec2 describe-instance-status
    else
        echo "Terminating instance with id $instance_id."
        aws ec2 terminate-instances --instance-ids $instance_id

        set_config instance_id ""
        set_config instance_ip ""
    fi
elif [ "$command" == "start" ]; then
    echo "Starting instance..." --ami $ami \
        --subnetId $subnetId \
        --securityGroupId $securityGroupId \
        --key_name $key_name \
        --volume_size $volume_size \
        --ec2spotter_instance_type $ec2spotter_instance_type \
        --bid_price $bid_price

    # Create a config file to launch the instance.
    cat >specs.tmp <<EOF
    {
      "ImageId" : "$ami",
      "InstanceType": "$ec2spotter_instance_type",
      "KeyName" : "$key_name",
      "EbsOptimized": true,
      "BlockDeviceMappings": [
        {
          "DeviceName": "/dev/sda1",
          "Ebs": {
            "DeleteOnTermination": true,
            "VolumeType": "gp2",
            "VolumeSize": $volume_size
          }
        }
      ],
      "NetworkInterfaces": [
          {
            "DeviceIndex": 0,
            "SubnetId": "${subnetId}",
            "Groups": [ "${securityGroupId}" ],
            "AssociatePublicIpAddress": true
          }
      ]
    }
EOF

    # Request the spot instance
    export request_id=`aws ec2 request-spot-instances --launch-specification file://specs.tmp --spot-price $bid_price --output="text" --query="SpotInstanceRequests[*].SpotInstanceRequestId"`

    echo Waiting for spot request to be fulfilled...
    aws ec2 wait spot-instance-request-fulfilled --spot-instance-request-ids $request_id

    # Get the instance id
    export instance_id=`aws ec2 describe-spot-instance-requests --spot-instance-request-ids $request_id --query="SpotInstanceRequests[*].InstanceId" --output="text"`

    echo Waiting for spot instance to start up...
    aws ec2 wait instance-running --instance-ids $instance_id

    echo Spot instance ID: $instance_id

    # Change the instance name
    aws ec2 create-tags --resources $instance_id --tags --tags Key=Name,Value=$name-gpu-machine

    # Get the instance IP
    export instance_ip=`aws ec2 describe-instances --instance-ids $instance_id --filter Name=instance-state-name,Values=running --query "Reservations[*].Instances[*].PublicIpAddress" --output=text`

    echo Spot Instance IP: $instance_ip

    # Clean up
    rm specs.tmp

    set_config instance_id $instance_id
    set_config instance_ip $instance_ip

    echo ""
    echo "Add the IP to your DNS as $instance_domain_name by calling:"
    echo "    sudo ml set_dns_config"
    echo "(or run sed -i.bak \"/$instance_domain_name/s/.*/$instance_ip     $instance_domain_name/\" $dns_file_path) $dns_file_path"

    echo ""
    echo "Connect in ssh using:"
    echo "    ssh ubuntu@$instance_domain_name"

    if [ "$persistent_volume_id" == "" ]; then
        echo "this instance will not persist anything."
    else
        echo "Attaching persistent volume $persistent_volume_id as $persistent_mount_device..."
        aws ec2 attach-volume --volume-id $persistent_volume_id --instance-id $instance_id --device $persistent_mount_device
        echo "Waiting for the volume to be attached attached..."
        DATA_STATE="unknown"
        until [ "$DATA_STATE" == "attached" ]; do
          sleep 3
          DATA_STATE=$(aws ec2 describe-volumes \
            --filters \
                Name=attachment.instance-id,Values=$instance_id \
                Name=attachment.device,Values=/dev/sdh \
            --query Volumes[].Attachments[].State \
            --output text)
        done

        # cf https://www.karelbemelmans.com/2016/11/ec2-userdata-script-that-waits-for-volumes-to-be-properly-attached-before-proceeding/
        echo "You may want to run the following commands to create a file system on the volume:"
        echo "    if [ \"\$(sudo file -b -s $persistent_mount_device)\" == \"data\" ]; then"
        echo "      sudo mkfs -t ext4 \"$persistent_mount_device\""
        echo "    fi"

        echo "Then you may want to mount the volume:"
        echo "    mkdir -p $persistent_mount_point"
        echo "    sudo mount $persistent_mount_device $persistent_mount_point"
        echo "    sudo chown ubuntu:ubuntu persist"

        echo "And you may even want to persist the volume in /etc/fstab so it gets mounted again"
        echo "    '$persistent_mount_device $persistent_mount_point ext4 defaults,nofail 0 2' >> /etc/fstab"

        echo ""
        echo "Waiting for spot instance to be ok before mounting the attached volume..."
        aws ec2 wait instance-status-ok --instance-ids $instance_id

        echo "Mounting the attached volume:"
        echo "ssh -t ubuntu@$instance_ip \"mkdir -p $persistent_mount_point; sudo mount $persistent_mount_device $persistent_mount_point; sudo chown ubuntu:ubuntu persist; touch imDone;\""
        ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t ubuntu@$instance_ip "mkdir -p $persistent_mount_point; sudo mount $persistent_mount_device $persistent_mount_point; sudo chown ubuntu:ubuntu persist; touch imDone;"
    fi

    echo ""
    echo "Waiting for spot instance to be ok... (you may simply interrupt the script)"
    aws ec2 wait instance-status-ok --instance-ids $instance_id
else
    echo "Unknown command $command"
fi