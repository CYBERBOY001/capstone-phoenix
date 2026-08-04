

resource "aws_instance" "control_plane" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.public_subnet_ids[0]
  vpc_security_group_ids      = [var.security_group_id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted = true
    delete_on_termination = true

    tags = {
        Name = "${var.project_name}-${var.environment}-control-plane"
    Role = "control-plane"
    }
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-control-plane"
    Role = "control-plane"
  }

  lifecycle {
    create_before_destroy = true
  }
}



resource "aws_instance" "workers" {
  count = var.worker_count

  ami                         = var.ami_id
  instance_type               = var.instance_type

  subnet_id = element(
    var.public_subnet_ids,
    (count.index + 1) % length(var.public_subnet_ids)
  )

  vpc_security_group_ids      = [var.security_group_id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 15
    volume_type = "gp3"
    encrypted = true
    delete_on_termination = true

    tags = {
        Name = "${var.project_name}-${var.environment}-workers"
    Role = "workers"
    }
    
  }
  tags = {
    Name = "${var.project_name}-${var.environment}-worker-${count.index + 1}"
    Role = "worker"
  }

  lifecycle {
    create_before_destroy = true
  }
}