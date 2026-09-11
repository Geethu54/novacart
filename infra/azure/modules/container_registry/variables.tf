variable "name" {
  description = "Globally-unique ACR name. Letters and numbers only (no hyphens/underscores) per Azure's naming rules."
  type        = string
}

variable "location" {
  description = "Azure region to create the registry in."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the registry is created in."
  type        = string
}

variable "sku" {
  description = "ACR SKU. Basic is enough for a dev environment holding two small app images."
  type        = string
  default     = "Basic"
}

variable "tags" {
  description = "Tags applied to the registry."
  type        = map(string)
  default     = {}
}
