# Naming convention: "<resource-type-abbreviation>-<project>-<environment>",
# e.g. rg-novacart-dev, log-novacart-dev, cae-novacart-dev. This keeps every
# resource's purpose and environment readable straight from its name in the
# Azure portal. PostgreSQL server names must be globally unique across all of
# Azure, so that one additionally gets a random suffix (see main.tf).
locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = merge(
    {
      project     = var.project
      environment = var.environment
      managed_by  = "terraform"
    },
    var.tags,
  )
}
