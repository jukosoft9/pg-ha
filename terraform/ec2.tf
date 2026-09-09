data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_iam_role" "node" {
  name = "${var.project}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.project}-node-profile"
  role = aws_iam_role.node.name
}

locals {
  pg_nodes = {
    pg1 = { az_index = 0 }
    pg2 = { az_index = 1 }
    pg3 = { az_index = 2 }
  }
}

resource "aws_instance" "pg" {
  for_each                    = local.pg_nodes
  ami                          = data.aws_ami.ubuntu.id
  lifecycle {
    ignore_changes = [ami]
  }
  instance_type                = var.pg_instance_type
  subnet_id                    = aws_subnet.private[each.value.az_index].id
  vpc_security_group_ids       = [aws_security_group.pg.id]
  key_name                     = var.key_pair_name
  iam_instance_profile         = aws_iam_instance_profile.node.name
  associate_public_ip_address  = false

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-${each.key}", Component = "postgresql" }
}

resource "aws_ebs_volume" "pgdata" {
  for_each          = local.pg_nodes
  availability_zone = var.azs[each.value.az_index]
  size              = var.pgdata_volume_size_gb
  type              = "gp3"
  tags              = { Name = "${var.project}-${each.key}-pgdata" }
}

resource "aws_volume_attachment" "pgdata" {
  for_each    = local.pg_nodes
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.pgdata[each.key].id
  instance_id = aws_instance.pg[each.key].id
}

resource "aws_ebs_volume" "pgwal" {
  for_each          = local.pg_nodes
  availability_zone = var.azs[each.value.az_index]
  size              = var.pgwal_volume_size_gb
  type              = "gp3"
  tags              = { Name = "${var.project}-${each.key}-pgwal" }
}

resource "aws_volume_attachment" "pgwal" {
  for_each    = local.pg_nodes
  device_name = "/dev/xvdg"
  volume_id   = aws_ebs_volume.pgwal[each.key].id
  instance_id = aws_instance.pg[each.key].id
}

resource "aws_ebs_volume" "etcd" {
  for_each          = local.pg_nodes
  availability_zone = var.azs[each.value.az_index]
  size              = var.etcd_volume_size_gb
  type              = "gp3"
  tags              = { Name = "${var.project}-${each.key}-etcd" }
}

resource "aws_volume_attachment" "etcd" {
  for_each    = local.pg_nodes
  device_name = "/dev/xvdh"
  volume_id   = aws_ebs_volume.etcd[each.key].id
  instance_id = aws_instance.pg[each.key].id
}

resource "aws_instance" "lb" {
  for_each                     = { lb1 = 0, lb2 = 1 }
  ami                          = data.aws_ami.ubuntu.id
  lifecycle {
    ignore_changes = [ami]
  }
  instance_type                = var.lb_instance_type
  subnet_id                    = aws_subnet.private[each.value].id
  vpc_security_group_ids       = [aws_security_group.lb.id]
  key_name                     = var.key_pair_name
  iam_instance_profile         = aws_iam_instance_profile.node.name
  associate_public_ip_address  = false
  source_dest_check            = false # required for Keepalived VRRP — traffic for the VIP arrives addressed to an IP that isn't the instance's own, and AWS drops that by default unless this is off

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-${each.key}", Component = "loadbalancer" }
}

resource "aws_instance" "mon1" {
  ami                          = data.aws_ami.ubuntu.id
  lifecycle {
    ignore_changes = [ami]
  }
  instance_type                = var.mon_instance_type
  subnet_id                    = aws_subnet.private[0].id
  vpc_security_group_ids       = [aws_security_group.mon.id]
  key_name                     = var.key_pair_name
  iam_instance_profile         = aws_iam_instance_profile.node.name
  associate_public_ip_address  = false

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-mon1", Component = "monitoring" }
}