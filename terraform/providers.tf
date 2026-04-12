provider "grid" {
  mnemonic    = var.tfgrid_mnemonic
  network     = var.tfgrid_network
  rmb_timeout = var.tfgrid_rmb_timeout
}

provider "random" {}
