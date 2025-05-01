# nixos-infect-small


Intended to install NixOS on Vultr VPS using OpenTofu (Terraform):
```
nix-shell -p opentofu
mkdir my-infra ; cd my-infra
create host.tf
tofu init
export VULTR_API_KEY = Key ( or save VULTR_API_KEY = XXXX in terraform.tfvard )
tofu plan
tofu apply
```

host.tf
```
terraform {
  required_providers {
    vultr = {
      source = "vultr/vultr"
      version = "2.25.0"
    }
  }
}

# Configure the Vultr Provider
provider "vultr" {
  api_key = var.VULTR_API_KEY
  rate_limit = 100
  retry_limit = 3
}

variable "VULTR_API_KEY" {}

data "vultr_region" "default_region" {
  filter {
    name   = "city"
    values = ["Frankfurt"]
  }
}

data "vultr_os" "default_os" {
  filter {
    name   = "name"
    values = ["Ubuntu 24.04 LTS x64"]
  }
}

// Find the ID for a starter plan.
data "vultr_plan" "default_plan" {
  filter {
    name   = "monthly_cost"
    values = ["5"]
  }

  filter {
    name   = "ram"
    values = ["1024"]
  }
}

resource "vultr_instance" "nixos-1" {
    label       = "nixos-1"
    region      = "${data.vultr_region.default_region.id}"
    plan        = "${data.vultr_plan.default_plan.id}"
    os_id       = "${data.vultr_os.default_os.id}"
    hostname    = "nixos-1"
    tags        = [ "tofu" ]
    ssh_key_ids = ["${vultr_ssh_key.tofu-key.id}"]
#   enable_ipv6  = true
    user_data = "${file("cloud-config.yaml")}"

}

resource "vultr_ssh_key" "tofu-key" {
  name = "tofu-key"
  ssh_key = "ssh-ed25519 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX xx@yy.com"
}
```
