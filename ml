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
elif [ "$command" == "set_ssh_config" ]; then
    echo "Host dev.aws" >> ~/.ssh/config
    echo "   StrictHostKeyChecking no" >> ~/.ssh/config
    echo "   UserKnownHostsFile=/dev/null" >> ~/.ssh/config
elif [ "$command" == "set_dns_config" ]; then
    dns_file_path="/private/etc/hosts"
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
            "DeleteOnTermination": false,
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

    echo "Waiting for spot instance to be ok... (you may simply interrupt the script)"
    aws ec2 wait instance-status-ok --instance-ids $instance_id
else
    echo "Unknown command $command"
fi