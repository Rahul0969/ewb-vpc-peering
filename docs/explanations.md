# Explanations

## Forward path (App-A -> App-B)
App-A (10.10.2.10) sends to 10.20.1.10. The subnet route table ewb-rt-a-private matches the more specific 10.20.0.0/16 route and sends the packet to the peering connection. It arrives in VPC B, where ewb-sg-app-b allows ICMP echo request from 10.10.2.10/32.

## Return path (App-B -> App-A)
The echo reply goes to 10.10.2.10. ewb-rt-b-private has 10.10.0.0/16 -> pcx, so the reply returns over the peering connection. Security groups are stateful, so the reply needs no inbound rule on App-A.

## Why each route is needed
- Private A -> pcx for 10.20.0.0/16: forward path.
- Private B -> pcx for 10.10.0.0/16: return path. A one-way route is insufficient.
- Public A -> pcx for 10.20.0.0/16: ProxyJump makes the bastion open its own connection to App-B, and the more specific route beats 0.0.0.0/0.

## Viva answers
1. **Why is the return route needed?** Replies need a route back to the sender's CIDR; peering does not add routes automatically.
2. **Why is the App-B SSH source the bastion private IP?** The bastion opens a separate SSH connection to App-B, so App-B sees 10.10.1.10 as the source.
3. **Why does Active peering not guarantee a ping?** Peering is only the link. Route tables and security groups (and NACLs) decide if traffic flows.
4. **Can VPC B use VPC A's internet gateway over peering?** No. Peering is non-transitive and does not forward internet traffic through the peer.

## Controlled failure
I removed only the ICMP echo-request rule (source 10.10.2.10/32) from ewb-sg-app-b, repeated the ping from App-A and the replies stopped, because the destination security group dropped the packets even though routing was fine. After restoring the exact rule, replies resumed. SSH rule was left in place.

## What I learned
WRITE 3-5 SENTENCES IN YOUR OWN WORDS from your actual experience (e.g. what failed first, what fixed it).
