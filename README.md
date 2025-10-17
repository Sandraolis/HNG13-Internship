# Deploy an NGINX Web Server on AWS.
**Task-1**

# 🎉 Welcome to my first DevOps challenge!

## ✅ This task will test my ability to deploy a web server and manage a GitHub repository.
It’s designed to mimic `real-world DevOps work` I’ll encounter in production.

## 🧩 Objectives
By the end of this assignment, I should be able to:
- Set up and manage a GitHub workflow.
- Deploy and configure a live NGINX web server.
- Serve a custom webpage accessible from the internet.

# 🧩Task Breakdown
## Part 1`:
1. Setting up my GitHub and I
Fork this repo:`hng13-stage0-devops`
In my fork:
I added a README.md to the main branch containing:
- My name
- My Slack username
- A short project description of the task.

`Part 2` Nginx Web Server Deployment

👏I built my own AWS network from scratch — complete with subnets, internet gateway, route tables, and security groups — and then deploy my NGINX web server inside it.

## 🧭 overview
I created 
- A `VPC`
- 2 `public subnets` for redundancy, availability accross AZs and scalability.
- An `Internet Gateway` (IGW)
- A `Route Table` (with a route to the IGW)
- A `Security Group` (for HTTP + SSH)
- An `EC2 instance` in that subnet running `NGINX`.

1. ### I created a VPC with a cidr block 10.0.0.0/16

2. ### I created two public subnets 

- `public-sub1` with AZ (us-east-1a) and cidr block 10.0.1.0/24
- `public-sub2` with AZ (us-east-2b) and cidr block 10.0.2.0/24

### Then I made it public..
I edited each of the subnet setting
by ✅ Enabling auto-assign public IPv4 address.

3. ### I created and attached internet gateway to the VPC

4. ### I created a route table and edited the routes to add
destination: 0.0.0.0./0 traffic from anywhere and the target was IGW that I created.

5. ### I created a Security Group and allowed two Inbound rules
- HTTP---80---0.0.0.0/0
- SSH---22---0.0.0.0/0

6. ## 💻 Launch an EC2 Instance in the Custom VPC and its dependencies
- AMI: Ubuntu
- Network: selected my vpc
- Subnet: selected public-subnet1
- Auto-assign public IP: Enable
- Security Group: selected the SG I created.

7. ## 🧩 Install and Configure NGINX

- I connected to the EC2 server, then installed and configured the nginx

``` bash
sudo apt update -y
sudo apt install nginx -y
sudo systemctl enable nginx
sudo systemctl start nginx
sudo systemctl status nginx
```

8. I edited my web page using this command 

``` bash
sudo vi /var/www/html/index.html
```
I pasted the content of the`index.html` file I forked for this project and edited as instructed by my Instructor

9. TEST

I copy my server public IP address and pasted it on my browser

``` bash
http://<my-ec2-public-ip>
```

![](./Images/1.%20nginx-server.png)






















