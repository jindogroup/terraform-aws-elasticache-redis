locals {
  subnet_group_name = var.subnet_group_name != null ? var.subnet_group_name : aws_elasticache_subnet_group.redis[0].name
}

resource "aws_elasticache_replication_group" "redis" {
  engine = var.global_replication_group_id == null ? "redis" : null

  parameter_group_name = var.global_replication_group_id == null ? aws_elasticache_parameter_group.redis.name : null
  subnet_group_name    = local.subnet_group_name
  security_group_ids   = concat(var.security_group_ids, [aws_security_group.redis.id])

  preferred_cache_cluster_azs = var.preferred_cache_cluster_azs
  replication_group_id        = var.global_replication_group_id == null ? "${var.name_prefix}-redis" : "${var.name_prefix}-redis-replica"
  num_cache_clusters          = var.cluster_mode_enabled ? null : var.num_cache_clusters
  node_type                   = var.global_replication_group_id == null ? var.node_type : null

  engine_version = var.global_replication_group_id == null ? var.engine_version : null
  port           = var.port

  maintenance_window         = var.maintenance_window
  snapshot_window            = var.snapshot_window
  snapshot_retention_limit   = var.snapshot_retention_limit
  snapshot_name              = var.snapshot_name
  final_snapshot_identifier  = var.final_snapshot_identifier
  automatic_failover_enabled = var.automatic_failover_enabled && var.num_cache_clusters >= 2 ? true : false
  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  multi_az_enabled           = var.multi_az_enabled

  at_rest_encryption_enabled  = var.global_replication_group_id == null ? var.at_rest_encryption_enabled : null
  transit_encryption_enabled  = var.global_replication_group_id == null ? var.transit_encryption_enabled : null
  auth_token                  = var.auth_token != "" ? var.auth_token : null
  kms_key_id                  = var.kms_key_id
  global_replication_group_id = var.global_replication_group_id

  apply_immediately = var.apply_immediately

  description = var.description

  data_tiering_enabled = var.data_tiering_enabled

  notification_topic_arn = var.notification_topic_arn

  replicas_per_node_group = var.cluster_mode_enabled ? var.replicas_per_node_group : null
  num_node_groups         = var.cluster_mode_enabled ? var.num_node_groups : null

  user_group_ids = var.user_group_ids

  dynamic "log_delivery_configuration" {
    for_each = var.log_delivery_configuration

    content {
      destination_type = log_delivery_configuration.value.destination_type
      destination      = log_delivery_configuration.value.destination
      log_format       = log_delivery_configuration.value.log_format
      log_type         = log_delivery_configuration.value.log_type
    }
  }

  tags = merge(
    {
      "Name" = "${var.name_prefix}-redis"
    },
    var.tags,
  )
}

resource "random_id" "redis_pg" {
  keepers = {
    family = var.family
  }

  byte_length = 2
}

resource "aws_elasticache_parameter_group" "redis" {
  name        = "${var.name_prefix}-redis-${random_id.redis_pg.hex}"
  family      = var.family
  description = var.parameter_group_description != null ? var.parameter_group_description : "Elasticache parameter group managed by Terraform"

  dynamic "parameter" {
    for_each = var.num_node_groups > 0 ? concat([{ name = "cluster-enabled", value = "yes" }], var.parameter) : var.parameter
    content {
      name  = parameter.value.name
      value = parameter.value.value
    }
  }

  # Ignore changes to the description since it will try to recreate the resource
  lifecycle {
    ignore_changes = [
      description,
    ]
  }

  tags = var.tags
}

resource "aws_elasticache_subnet_group" "redis" {
  count = var.subnet_group_name == null && length(var.subnet_ids) > 0 ? 1 : 0

  name        = var.global_replication_group_id == null ? "${var.name_prefix}-redis-sg" : "${var.name_prefix}-redis-sg-replica"
  subnet_ids  = var.subnet_ids
  description = "Elasticache subnet group for ${var.description}"

  tags = var.tags
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.name_prefix}-redis-"
  vpc_id      = var.vpc_id

  tags = merge(
    {
      "Name" = "${var.name_prefix}-redis"
    },
    var.tags
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "redis_ingress_self" {
  count = var.ingress_self ? 1 : 0

  type              = "ingress"
  from_port         = var.port
  to_port           = var.port
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.redis.id
}

resource "aws_security_group_rule" "redis_ingress_cidr_blocks" {
  count = length(var.ingress_cidr_blocks) != 0 ? 1 : 0

  type              = "ingress"
  from_port         = var.port
  to_port           = var.port
  protocol          = "tcp"
  cidr_blocks       = var.ingress_cidr_blocks
  security_group_id = aws_security_group.redis.id
}

resource "aws_security_group_rule" "redis_egress" {
  count = length(var.egress_cidr_blocks) != 0 ? 1 : 0

  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = var.egress_cidr_blocks
  security_group_id = aws_security_group.redis.id
}

resource "aws_security_group_rule" "other_sg_ingress" {
  count                    = length(var.allowed_security_groups)
  type                     = "ingress"
  from_port                = var.port
  to_port                  = var.port
  protocol                 = "tcp"
  source_security_group_id = element(var.allowed_security_groups, count.index)
  security_group_id        = aws_security_group.redis.id
}

locals {

  # if !cluster, then node_count = replica cluster_size, if cluster then node_count = shard*(replica + 1)
  # Why doing this 'The "count" value depends on resource attributes that cannot be determined until apply'. So pre-calculating
  member_clusters_count = (var.cluster_mode_enabled
    ?
    (var.num_node_groups * (var.replicas_per_node_group+ 1))
    :
    var.num_cache_clusters
  )

  elasticache_member_clusters = tolist(aws_elasticache_replication_group.redis.member_clusters)
}




resource "aws_cloudwatch_metric_alarm" "cache_cpu" {
  count               =  var.cloudwatch_metric_alarms_enabled ? local.member_clusters_count : 0
  alarm_name          = "${element(local.elasticache_member_clusters, count.index)}-cpu-utilization"
  alarm_description   = "Redis cluster CPU utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = "300"
  statistic           = "Average"

  threshold = var.alarm_cpu_threshold_percent

  dimensions = {
    CacheClusterId = element(local.elasticache_member_clusters, count.index)
  }

  alarm_actions = var.alarm_actions
  ok_actions    = var.ok_actions
  depends_on    = [aws_elasticache_replication_group.redis]

}

resource "aws_cloudwatch_metric_alarm" "cache_memory" {
  count               = var.cloudwatch_metric_alarms_enabled ? local.member_clusters_count : 0
  alarm_name          = "${element(local.elasticache_member_clusters, count.index)}-freeable-memory"
  alarm_description   = "Redis cluster freeable memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "FreeableMemory"
  namespace           = "AWS/ElastiCache"
  period              = "60"
  statistic           = "Average"

  threshold = var.alarm_memory_threshold_bytes

  dimensions = {
    CacheClusterId = element(local.elasticache_member_clusters, count.index)
  }

  alarm_actions = var.alarm_actions
  ok_actions    = var.ok_actions
  depends_on    = [aws_elasticache_replication_group.redis]

}
