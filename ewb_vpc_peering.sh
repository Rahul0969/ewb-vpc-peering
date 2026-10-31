#!/usr/bin/env bash
# EWB AWS VPC Peering lab - run from YOUR laptop (WSL/macOS/Linux) with AWS CLI v2 configured.
# Usage: STUDENT="Your Name" ./ewb_vpc_peering.sh <phase>
#   build    -> VPCs, subnets, IGW, route tables, SGs, key pair, 3 instances, ~/.ssh/config
#   baseline -> Test 01 (ping must FAIL before peering)
#   peer     -> create + accept peering, add routes on all 3 route tables
#   verify   -> Tests 02-05 (forward, reverse, SSH to App-B, no public IPs)
#   failure  -> controlled ICMP failure and recovery
#   cleanup  -> delete everything (save evidence first!)
# Copy each phase's terminal output into your report PDF.
set -euo pipefail
export AWS_REGION="${AWS_REGION:-ap-south-1}" AWS_DEFAULT_REGION="${AWS_REGION:-ap-south-1}"
AZ="${AZ:-${AWS_REGION}a}"
STUDENT="${STUDENT:?set STUDENT=\"Your Name\"}"
S="$HOME/.ewb-state.env"; touch "$S"; source "$S"
save(){ echo "$1=$2" >> "$S"; export "$1=$2"; echo "  $1 = $2"; }
tags(){ echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=EWB-VPC-Peering},{Key=Student,Value=$STUDENT}]"; }
q(){ aws ec2 "$@" --output text; }

build(){
  echo "== VPC A =="
  save VPCA $(q create-vpc --cidr-block 10.10.0.0/16 --tag-specifications "$(tags vpc ewb-vpc-a)" --query Vpc.VpcId)
  save SUBPUB $(q create-subnet --vpc-id $VPCA --cidr-block 10.10.1.0/24 --availability-zone $AZ --tag-specifications "$(tags subnet ewb-a-public)" --query Subnet.SubnetId)
  save SUBPRIVA $(q create-subnet --vpc-id $VPCA --cidr-block 10.10.2.0/24 --availability-zone $AZ --tag-specifications "$(tags subnet ewb-a-private)" --query Subnet.SubnetId)
  save IGW $(q create-internet-gateway --tag-specifications "$(tags internet-gateway ewb-igw-a)" --query InternetGateway.InternetGatewayId)
  q attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPCA
  save RTPUB $(q create-route-table --vpc-id $VPCA --tag-specifications "$(tags route-table ewb-rt-a-public)" --query RouteTable.RouteTableId)
  q associate-route-table --route-table-id $RTPUB --subnet-id $SUBPUB >/dev/null
  q create-route --route-table-id $RTPUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW >/dev/null
  save RTPRIVA $(q create-route-table --vpc-id $VPCA --tag-specifications "$(tags route-table ewb-rt-a-private)" --query RouteTable.RouteTableId)
  q associate-route-table --route-table-id $RTPRIVA --subnet-id $SUBPRIVA >/dev/null

  echo "== VPC B =="
  save VPCB $(q create-vpc --cidr-block 10.20.0.0/16 --tag-specifications "$(tags vpc ewb-vpc-b)" --query Vpc.VpcId)
  save SUBPRIVB $(q create-subnet --vpc-id $VPCB --cidr-block 10.20.1.0/24 --availability-zone $AZ --tag-specifications "$(tags subnet ewb-b-private)" --query Subnet.SubnetId)
  save RTPRIVB $(q create-route-table --vpc-id $VPCB --tag-specifications "$(tags route-table ewb-rt-b-private)" --query RouteTable.RouteTableId)
  q associate-route-table --route-table-id $RTPRIVB --subnet-id $SUBPRIVB >/dev/null

  echo "== Security groups =="
  MYIP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')
  save SGBASTION $(q create-security-group --group-name ewb-sg-bastion --description "EWB bastion" --vpc-id $VPCA --tag-specifications "$(tags security-group ewb-sg-bastion)" --query GroupId)
  save SGAPPA $(q create-security-group --group-name ewb-sg-app-a --description "EWB app A" --vpc-id $VPCA --tag-specifications "$(tags security-group ewb-sg-app-a)" --query GroupId)
  save SGAPPB $(q create-security-group --group-name ewb-sg-app-b --description "EWB app B" --vpc-id $VPCB --tag-specifications "$(tags security-group ewb-sg-app-b)" --query GroupId)
  q authorize-security-group-ingress --group-id $SGBASTION --protocol tcp --port 22 --cidr $MYIP/32 >/dev/null
  q authorize-security-group-ingress --group-id $SGAPPA --protocol tcp --port 22 --cidr 10.10.1.10/32 >/dev/null
  q authorize-security-group-ingress --group-id $SGAPPA --ip-permissions 'IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.20.1.10/32}]' >/dev/null
  q authorize-security-group-ingress --group-id $SGAPPB --protocol tcp --port 22 --cidr 10.10.1.10/32 >/dev/null
  q authorize-security-group-ingress --group-id $SGAPPB --ip-permissions 'IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.10.2.10/32}]' >/dev/null

  echo "== Key pair =="
  aws ec2 create-key-pair --key-name ewb-lab --key-type rsa --query KeyMaterial --output text > "$HOME/.ssh/ewb-lab.pem"
  chmod 400 "$HOME/.ssh/ewb-lab.pem"

  echo "== Instances =="
  AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
  BDM='[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","DeleteOnTermination":true}}]'
  launch(){ # name subnet ip sg publicflag
    q run-instances --image-id $AMI --instance-type t3.micro --key-name ewb-lab --block-device-mappings "$BDM" \
      --network-interfaces "DeviceIndex=0,SubnetId=$2,PrivateIpAddress=$3,Groups=$4,AssociatePublicIpAddress=$5" \
      --tag-specifications "$(tags instance $1)" --query 'Instances[0].InstanceId'; }
  save IBASTION $(launch ewb-bastion $SUBPUB 10.10.1.10 $SGBASTION true)
  save IAPPA $(launch ewb-app-a $SUBPRIVA 10.10.2.10 $SGAPPA false)
  save IAPPB $(launch ewb-app-b $SUBPRIVB 10.20.1.10 $SGAPPB false)
  aws ec2 wait instance-status-ok --instance-ids $IBASTION $IAPPA $IAPPB
  BIP=$(q describe-instances --instance-ids $IBASTION --query 'Reservations[0].Instances[0].PublicIpAddress')
  save BASTION_IP $BIP

  mkdir -p ~/.ssh
  cat >> ~/.ssh/config <<EOF

Host ewb-bastion
    HostName $BIP
    User ec2-user
    IdentityFile ~/.ssh/ewb-lab.pem
    IdentitiesOnly yes
Host ewb-app-a
    HostName 10.10.2.10
    User ec2-user
    IdentityFile ~/.ssh/ewb-lab.pem
    IdentitiesOnly yes
    ProxyJump ewb-bastion
Host ewb-app-b
    HostName 10.20.1.10
    User ec2-user
    IdentityFile ~/.ssh/ewb-lab.pem
    IdentitiesOnly yes
    ProxyJump ewb-bastion
EOF
  echo "== Checkpoint 01/02: screenshot route tables + instance list now =="
  echo "Now run: ssh ewb-bastion  (type exit), then ssh ewb-app-a (verify host key prompt)"
}

baseline(){ echo "== Test 01 baseline (expect 100% loss) =="
  ssh ewb-app-a 'hostname; hostname -I; ping -c 4 -W 2 10.20.1.10' || echo "(no replies - expected)"; }

peer(){
  save PCX $(q create-vpc-peering-connection --vpc-id $VPCA --peer-vpc-id $VPCB --tag-specifications "$(tags vpc-peering-connection ewb-a-b-peer)" --query VpcPeeringConnection.VpcPeeringConnectionId)
  q accept-vpc-peering-connection --vpc-peering-connection-id $PCX >/dev/null
  aws ec2 wait vpc-peering-connection-exists --vpc-peering-connection-ids $PCX
  q create-route --route-table-id $RTPRIVA --destination-cidr-block 10.20.0.0/16 --vpc-peering-connection-id $PCX >/dev/null
  q create-route --route-table-id $RTPRIVB --destination-cidr-block 10.10.0.0/16 --vpc-peering-connection-id $PCX >/dev/null
  q create-route --route-table-id $RTPUB   --destination-cidr-block 10.20.0.0/16 --vpc-peering-connection-id $PCX >/dev/null
  echo "== Checkpoint 03/04: screenshot Active peering and the 3 route tables =="
  aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids $PCX \
    --query 'VpcPeeringConnections[0].[Status.Code,RequesterVpcInfo.VpcId,AccepterVpcInfo.VpcId]'
}

verify(){
  echo "== Test 02 forward (App-A -> App-B) =="; ssh ewb-app-a 'hostname; hostname -I; ping -c 4 10.20.1.10'
  echo "== Test 03 reverse (App-B -> App-A) =="; ssh ewb-app-b 'hostname; hostname -I; ping -c 4 10.10.2.10'
  echo "== Test 04 private SSH =="; ssh ewb-app-b 'echo connected to $(hostname) via bastion'
  echo "== Test 05 isolation (expect None / None) =="
  q describe-instances --instance-ids $IAPPA $IAPPB --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PublicIpAddress]'
}

failure(){
  P='IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.10.2.10/32}]'
  echo "== Remove App-B ICMP rule =="; q revoke-security-group-ingress --group-id $SGAPPB --ip-permissions "$P" >/dev/null
  sleep 5; ssh ewb-app-a 'ping -c 4 -W 2 10.20.1.10' || echo "(replies stopped - expected)"
  echo "== Restore the exact rule =="; q authorize-security-group-ingress --group-id $SGAPPB --ip-permissions "$P" >/dev/null
  sleep 5; ssh ewb-app-a 'ping -c 4 10.20.1.10'
}

cleanup(){
  q terminate-instances --instance-ids $IBASTION $IAPPA $IAPPB >/dev/null
  aws ec2 wait instance-terminated --instance-ids $IBASTION $IAPPA $IAPPB
  q delete-route --route-table-id $RTPRIVA --destination-cidr-block 10.20.0.0/16
  q delete-route --route-table-id $RTPRIVB --destination-cidr-block 10.10.0.0/16
  q delete-route --route-table-id $RTPUB   --destination-cidr-block 10.20.0.0/16
  q delete-vpc-peering-connection --vpc-peering-connection-id $PCX >/dev/null
  sleep 20
  for sg in $SGBASTION $SGAPPA $SGAPPB; do q delete-security-group --group-id $sg; done
  for sn in $SUBPUB $SUBPRIVA $SUBPRIVB; do q delete-subnet --subnet-id $sn; done
  for rt in $RTPUB $RTPRIVA $RTPRIVB; do q delete-route-table --route-table-id $rt; done
  q detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPCA
  q delete-internet-gateway --internet-gateway-id $IGW
  q delete-vpc --vpc-id $VPCA; q delete-vpc --vpc-id $VPCB
  q delete-key-pair --key-name ewb-lab; rm -f ~/.ssh/ewb-lab.pem
  echo "== Verify: should list nothing =="
  q describe-vpcs --filters Name=tag:Project,Values=EWB-VPC-Peering --query 'Vpcs[].VpcId'
  q describe-volumes --filters Name=tag:Project,Values=EWB-VPC-Peering --query 'Volumes[].VolumeId'
  echo "Also remove the 3 ewb-* Host blocks from ~/.ssh/config and check Billing."
}

"${1:?phase: build|baseline|peer|verify|failure|cleanup}"
