provider "aws" {
  region = "us-east-1"
}

resource "aws_instance" "app" {
  instance_type     = "t2.micro"
  ami               = "ami-08b5b3a93ed654d19"
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              sudo yum update -y
              sudo yum install -y httpd
              sudo systemctl start httpd
              sudo systemctl enable httpd
              echo "<h1>Welcome to My EC2 Apache Server!</h1>" > /var/www/html/index.html
              EOF
user_data_replace_on_change = true
tags = {
Name = "terraform-example"
 }
}

resource "aws_security_group" "web_sg" {
  name        = "web-server-sg"
  description = "Allow HTTP traffic"

  ingress {
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Open to all (modify for security)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "WebServerSecurityGroup"
  }
}

resource "aws_launch_template" "app" {
  instance_type     = "t2.micro"
  image_id          = "ami-08b5b3a93ed654d19"
  vpc_security_group_ids   = [aws_security_group.web_sg.id]

  user_data = base64encode (<<-EOF
              #!/bin/bash
              sudo yum update -y
              sudo yum install -y httpd
              sudo systemctl start httpd
              sudo systemctl enable httpd
              echo "<h1>Welcome to My EC2 Apache Server!</h1>" > /var/www/html/index.html
              EOF
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB"
  min_size = 2
  max_size = 10

launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

tag {
  key = "Name"
  value = "terraform-asg-example"
  propagate_at_launch = true
}
}

data "aws_vpc" "default" {
default = true
}

data "aws_subnets" "default" {
filter {
name = "vpc-id"
values = [data.aws_vpc.default.id]
}
}
### Load Balancer ######

resource "aws_lb" "app" {
  name = "terraform-asg-example"
  load_balancer_type = "application"
  subnets = data.aws_subnets.default.ids
  security_groups = [aws_security_group.alb.id]
}
### Listener ####

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port = 80
  protocol = "HTTP"
# By default, return a simple 404 page
default_action {
  type = "fixed-response"
fixed_response {
  content_type = "text/plain"
  message_body = "404: page not found"
  status_code = 404
}
}
}

### security group for ALB ###

resource "aws_security_group" "alb" {
  name = "terraform-example-alb"
# Allow inbound HTTP requests
ingress {
  from_port = 80
  to_port = 80
  protocol = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}
# Allow all outbound requests
egress {
  from_port = 0
  to_port = 0
  protocol = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}
}

resource "aws_lb_target_group" "asg" {
  name = "terraform-asg-example"
  port = var.server_port
  protocol = "HTTP"
  vpc_id = data.aws_vpc.default.id

health_check {
  path = "/"
  protocol = "HTTP"
  matcher = "200"
  interval = 15
  timeout = 3
  healthy_threshold = 2
  unhealthy_threshold = 2
}
}
## Listener rules ####
resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority = 100
  condition {
    path_pattern {
      values = ["*"]
    }
  }
  action {
    type = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}