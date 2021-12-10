provider "google" {
  user_project_override = true
  access_token          = var.access_token
}

provider "google-beta"{
  access_token          = var.access_token
  project               = "airline1-sabre-wolverine"
}

# VPC
resource "google_compute_network" "ilb_network" {
  name                    = "my-dev-appid-strg-demolb-network"
  provider                = google-beta
  auto_create_subnetworks = false
  delete_default_routes_on_create   = true
  mtu                     = 1500
}

# proxy-only subnet
resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "my-dev-appid-strg-demoproxylb-subnet"
  provider      = google-beta
  ip_cidr_range = "10.0.0.0/24"
  region        = "europe-west1"
  purpose       = "INTERNAL_HTTPS_LOAD_BALANCER"
  role          = "ACTIVE"
  network       = google_compute_network.ilb_network.id
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 1.0
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# backed subnet
resource "google_compute_subnetwork" "ilb_subnet" {
  name          = "my-dev-appid-strg-demolb-subnet"
  provider      = google-beta
  ip_cidr_range = "10.0.1.0/24"
  region        = "europe-west1"
  network       = google_compute_network.ilb_network.id
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 1.0
    metadata             = "INCLUDE_ALL_METADATA"
  }  
}

# forwarding rule
resource "google_compute_forwarding_rule" "google_compute_forwarding_rule" {
  name                  = "my-dev-appid-strg-demolb-httpsilb"
  #name                  = "demolb-httpsilb"
  provider              = google-beta
  region                = "europe-west1"
  depends_on            = [google_compute_subnetwork.proxy_subnet]
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  #load_balancing_scheme = "EXTERNAL"
  port_range            =  "443"
  all_ports             = false
  target                = google_compute_region_target_http_proxy.default.id
  network               = google_compute_network.ilb_network.id
  subnetwork            = google_compute_subnetwork.ilb_subnet.id
  network_tier          = "PREMIUM"
  labels = {
    owner = "hybridenv"
    application_division = "pci"
    application_name = "app1"
    application_role = "auth"
    au = "0223092"
    gcp_region = "us" 
    environment = "dev" 
    created = "20211124" 
  }
}

# http proxy
resource "google_compute_region_target_http_proxy" "default" {
  name     = "my-dev-appid-strg-demolb-httpsproxy"
  #name     = "my-dev-appid-strg-demolb"
  provider = google-beta
  region   = "europe-west1"
  url_map  = google_compute_region_url_map.default.id
}

# url map
resource "google_compute_region_url_map" "default" {
  name            = "my-dev-appid-strg-demolb-map"
  provider        = google-beta
  region          = "europe-west1"
  default_service = google_compute_region_backend_service.default.id
}

# backend service
resource "google_compute_region_backend_service" "default" {
  name                  = "my-dev-appid-strg-demobcklb-subnet"
  provider              = google-beta
  region                = "europe-west1"
  protocol              = "HTTP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  timeout_sec           = 10
  health_checks         = [google_compute_region_health_check.default.id]
  backend {
    group           = google_compute_region_instance_group_manager.mig.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# instance template
resource "google_compute_instance_template" "instance_template" {
  name         = "my-dev-appid-strg-demomiglb-template"
  provider     = google-beta
  machine_type = "e2-small"
  tags         = ["http-server"]

  network_interface {
    network    = google_compute_network.ilb_network.id
    subnetwork = google_compute_subnetwork.ilb_subnet.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }

  # install nginx and serve a simple web page
  metadata = {
    startup-script = <<-EOF1
      #! /bin/bash
      set -euo pipefail

      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y nginx-light jq

      NAME=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/hostname")
      IP=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")
      METADATA=$(curl -f -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=True" | jq 'del(.["startup-script"])')

      cat <<EOF > /var/www/html/index.html
      <pre>
      Name: $NAME
      IP: $IP
      Metadata: $METADATA
      </pre>
      EOF
    EOF1
  }
  lifecycle {
    create_before_destroy = true
  }
}

# health check
resource "google_compute_region_health_check" "default" {
  name     = "my-dev-appid-strg-demolb-hc"
  provider = google-beta
  region   = "europe-west1"
  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}

# MIG
resource "google_compute_region_instance_group_manager" "mig" {
  name     = "my-dev-appid-strg-demolb-mig1"
  provider = google-beta
  region   = "europe-west1"
  version {
    instance_template = google_compute_instance_template.instance_template.id
    name              = "primary"
  }
  base_instance_name = "vm"
  target_size        = 2
}

# allow all access from IAP and health check ranges
resource "google_compute_firewall" "fw-iap" {
  name          = "my-dev-appid-strg-demolb-fw1"
  provider      = google-beta
  direction     = "INGRESS"
  network       = google_compute_network.ilb_network.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "35.235.240.0/20"]
  allow {
    protocol = "tcp"
  }
}

# allow http from proxy subnet to backends
resource "google_compute_firewall" "fw-ilb-to-backends" {
  name          = "my-dev-appid-strg-demolb-fw2"
  provider      = google-beta
  direction     = "INGRESS"
  network       = google_compute_network.ilb_network.id
  source_ranges = ["10.0.0.0/24"]
  target_tags   = ["http-server"]
  allow {
    protocol = "tcp"
    ports    = ["443",]
  }
}

# test instance
resource "google_compute_instance" "vm-test" {
  name         = "my-dev-appid-strg-demolb-vm"
  provider     = google-beta
  zone         = "europe-west1-b"
  machine_type = "e2-small"
  network_interface {
    network    = google_compute_network.ilb_network.id
    subnetwork = google_compute_subnetwork.ilb_subnet.id
  }
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-10"
    }
  }
}
