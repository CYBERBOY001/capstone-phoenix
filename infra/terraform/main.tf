module "network" {
  source = "./modules/network"

  project_name        = var.project_name
  environment         = var.environment
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs
  availability_zones  = var.availability_zones
}

module "security_group" {
  source = "./modules/security_group"

  project_name      = var.project_name
  environment       = var.environment
  vpc_id            = module.network.vpc_id
  allowed_ssh_cidrs = var.allowed_ssh_cidrs
}

module "compute" {
  source = "./modules/compute"

  project_name = var.project_name
  environment  = var.environment

  ami_id        = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name
  worker_count  = var.worker_count

  security_group_id = module.security_group.security_group_id
  public_subnet_ids = module.network.public_subnet_ids
}