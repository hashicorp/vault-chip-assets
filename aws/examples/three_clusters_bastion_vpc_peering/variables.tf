variable "tags" {
  default = {}
}
variable "region1" {
  default = "us-east-1"
}
variable "region2" {
  default = "us-east-2"
}
variable "region3" {
  default = "eu-central-1"
}

variable "vault_license" {
  type    = string
  default = null
}
