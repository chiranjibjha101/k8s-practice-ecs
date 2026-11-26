# EKS demo cluster (Terraform)

Creates a VPC (2 AZs, public + private subnets, 1 NAT gateway), an EKS control
plane, core add-ons, and a managed node group of 2 x t3.medium.

## Prerequisites
- Terraform >= 1.5, AWS CLI v2, kubectl
- AWS credentials for a sandbox account (`aws sts get-caller-identity` works)
- A budget alert set in AWS Billing

## Create
```bash
terraform init
terraform plan
terraform apply          # ~15-20 min
$(terraform output -raw configure_kubectl)
kubectl get nodes
```

## Deploy the sample app
```bash
kubectl create deployment hello --image=nginx --replicas=2
kubectl expose deployment hello --type=LoadBalancer --port=80
kubectl get svc hello -w   # wait for EXTERNAL-IP, open it in a browser
```

## Destroy (order matters)
Delete the Service FIRST so Kubernetes removes the AWS load balancer.
Otherwise the VPC destroy can hang on the leftover ELB/ENIs.
```bash
kubectl delete svc hello
kubectl delete deployment hello
terraform destroy
```
Then check the console: EC2 (instances, volumes, load balancers, Elastic IPs),
VPC (NAT gateways), CloudFormation/EKS (nothing left).

## Cost
Roughly $0.25-0.30/hr while running (control plane ~$0.10, nodes ~$0.08,
NAT ~$0.045 plus data, load balancer ~$0.025). Prices vary by region.

## Notes
- `terraform.tfstate` holds sensitive data; don't commit it. For real work,
  use an S3 backend with locking.
- Override defaults with `-var region=us-east-1` or a `terraform.tfvars` file.
