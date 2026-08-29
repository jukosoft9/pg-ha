resource "aws_security_group" "pg" {
  name        = "${var.project}-pg"
  description = "PostgreSQL + Patroni + etcd nodes"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-pg" }
}

resource "aws_security_group" "lb" {
  name        = "${var.project}-lb"
  description = "HAProxy + Keepalived"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-lb" }
}

resource "aws_security_group" "mon" {
  name        = "${var.project}-mon"
  description = "Prometheus/Grafana/Alertmanager/Loki"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-mon" }
}

# --- pg rules ---
resource "aws_security_group_rule" "pg_replication_and_etcd" {
  type                     = "ingress"
  from_port                = 2379
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.pg.id
  source_security_group_id = aws_security_group.pg.id
  description              = "covers 2379-2380 (etcd) and 5432 (replication) between PG nodes"
}

resource "aws_security_group_rule" "pg_from_lb_pgbouncer" {
  type                     = "ingress"
  from_port                = 6432
  to_port                  = 6432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.pg.id
  source_security_group_id = aws_security_group.lb.id
}

resource "aws_security_group_rule" "pg_patroni_rest_from_lb" {
  type                     = "ingress"
  from_port                = 8008
  to_port                  = 8008
  protocol                 = "tcp"
  security_group_id        = aws_security_group.pg.id
  source_security_group_id = aws_security_group.lb.id
}

resource "aws_security_group_rule" "pg_patroni_rest_from_mon" {
  type                     = "ingress"
  from_port                = 8008
  to_port                  = 8008
  protocol                 = "tcp"
  security_group_id        = aws_security_group.pg.id
  source_security_group_id = aws_security_group.mon.id
}

resource "aws_security_group_rule" "pg_exporters_from_mon" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9187
  protocol                 = "tcp"
  security_group_id        = aws_security_group.pg.id
  source_security_group_id = aws_security_group.mon.id
}

resource "aws_security_group_rule" "pg_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  security_group_id = aws_security_group.pg.id
  cidr_blocks       = [var.admin_cidr]
}

resource "aws_security_group_rule" "pg_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.pg.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# --- lb rules ---
resource "aws_security_group_rule" "lb_client_ports" {
  type              = "ingress"
  from_port         = 5000
  to_port           = 5001
  protocol          = "tcp"
  security_group_id = aws_security_group.lb.id
  cidr_blocks       = [var.vpc_cidr]
}

resource "aws_security_group_rule" "lb_vrrp" {
  type              = "ingress"
  from_port         = 112
  to_port           = 112
  protocol          = "112"
  security_group_id = aws_security_group.lb.id
  self              = true
}

resource "aws_security_group_rule" "lb_stats" {
  type                     = "ingress"
  from_port                = 7000
  to_port                  = 7000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lb.id
  source_security_group_id = aws_security_group.mon.id
}

resource "aws_security_group_rule" "lb_haproxy_exporter" {
  type                     = "ingress"
  from_port                = 9101
  to_port                  = 9101
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lb.id
  source_security_group_id = aws_security_group.mon.id
}

resource "aws_security_group_rule" "lb_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  security_group_id = aws_security_group.lb.id
  cidr_blocks       = [var.admin_cidr]
}

resource "aws_security_group_rule" "lb_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.lb.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# --- mon rules ---
resource "aws_security_group_rule" "mon_ui" {
  type              = "ingress"
  from_port         = 3000
  to_port           = 9093
  protocol          = "tcp"
  security_group_id = aws_security_group.mon.id
  cidr_blocks       = [var.admin_cidr]
}

resource "aws_security_group_rule" "mon_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  security_group_id = aws_security_group.mon.id
  cidr_blocks       = [var.admin_cidr]
}

resource "aws_security_group_rule" "mon_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.mon.id
  cidr_blocks       = ["0.0.0.0/0"]
}