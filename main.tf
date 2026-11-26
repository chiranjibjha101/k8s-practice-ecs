data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

################################################################################
# VPC: public + private subnets, one shared NAT gateway (cheaper for a demo)
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.16"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # production: one per AZ
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags the AWS Load Balancer integration uses to pick subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

################################################################################
# EKS: control plane (AWS-managed) + managed node group (you manage)
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public API endpoint so kubectl works from your laptop
  cluster_endpoint_public_access = true

  # Gives the identity running terraform admin access via an EKS access entry
  enable_cluster_creator_admin_permissions = true

  # Core add-ons (you own their versions)
  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
    eks-pod-identity-agent = {}
    aws-efs-csi-driver = {}
    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  eks_managed_node_groups = {
    ng-1 = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }
}



# In module "eks" -> cluster_addons, add:
#   eks-pod-identity-agent = {}

resource "aws_s3_bucket" "app" {
  bucket = "my-unique-demo-bucket-1255y54r4y345"   # must be globally unique
}

data "aws_iam_policy_document" "s3_access" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.app.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.app.arn}/*"]
  }
}

data "aws_iam_policy_document" "pod_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "s3_app" {
  name               = "${var.cluster_name}-s3-app"
  assume_role_policy = data.aws_iam_policy_document.pod_trust.json
}

resource "aws_iam_role_policy" "s3_app" {
  role   = aws_iam_role.s3_app.id
  policy = data.aws_iam_policy_document.s3_access.json
}

resource "aws_eks_pod_identity_association" "s3_app" {
  cluster_name    = module.eks.cluster_name
  namespace       = "default"
  service_account = "s3-app"
  role_arn        = aws_iam_role.s3_app.arn
}




///////////////////////////////////////////////////////////////////////   efs
# IAM role for the EFS CSI controller (Pod Identity)
resource "aws_iam_role" "efs_csi" {
  name = "${var.cluster_name}-efs-csi-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "efs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "efs-csi-controller-sa"
  role_arn        = aws_iam_role.efs_csi.arn

  depends_on = [module.eks]
}





/////////////////////////////////////---------------------------ebs


resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}