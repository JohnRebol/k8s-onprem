resource "local_file" "somefile" {
  filename = "${path.module}/somefile.txt"
  content  = "hi john"

}

resource "local_sensitive_file" "senname" {
  filename = "senative.txt"
  content  = "password"

}

resource "random_pet" "my-pet" {
  prefix    = "Mrs"
  separator = "."
  length    = "6"
}
