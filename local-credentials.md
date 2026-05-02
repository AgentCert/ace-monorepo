Langfuse ui:- http://localhost:4000
LANGFUSE_SECRET_KEY="sk-lf-2f3656a2-144d-43d2-a107-978dff36246e"
LANGFUSE_PUBLIC_KEY="pk-lf-d642024a-76dc-4480-8623-151fe096056c"
LANGFUSE_BASE_URL="http://localhost:4000"

MongoDB:
Host: localhost:27017
Username: admin
Password: 1234
Auth DB: admin
Replica Set: rs0
Connection URI: mongodb://admin:1234@localhost:27017/?authSource=admin&replicaSet=rs0
Container: mongodb (image mongo:5)
Volumes: mongodb_data (data), mongo-keyfile-vol (keyFile at /keydata/keyfile)


