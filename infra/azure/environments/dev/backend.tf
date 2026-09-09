# Local state for now. This directory is the entry point for the dev
# environment, applied directly with `terraform apply` from here.
#
# Before this environment is shared by more than one operator, switch to
# remote state (an azurerm storage account + container) so state is shared
# and locked instead of living on one machine's disk:
#
# terraform {
#   backend "azurerm" {
#     resource_group_name  = "rg-novacart-tfstate"
#     storage_account_name = "<globally-unique-storage-account>"
#     container_name       = "tfstate"
#     key                  = "novacart-dev.tfstate"
#   }
# }
#
# That storage account/container must be created out-of-band (or via a
# separate bootstrap Terraform run) before this block can be uncommented,
# since Terraform can't create the backend it's about to read state from.
