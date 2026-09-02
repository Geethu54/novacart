create .env file locally

new file under backend with below code 

APP_ENV=development
API_VERSION=v1
DATABASE_URL=sqlite:///./novacart.db

the above create a env file which we will be using during run time.

backend - 

Added Docker file in the backend folder 

create image - 

navigate to backend folder and run 

docker build -t <name> .

to create backend image .

similary navigate to front end folder and run
docker build -t <name> .
to create front end image .


Docker network - 

create a docker network novacart for front end and backend communication since both are different containers there will be no way to find  one container from another 

steps to create docker network 
docker network create <name>

once these are created we can use nginx 

docker run -d --name backend --network novacart-net -p 8000:8000 \               
  --env-file .env \
  -v "$(pwd)/novacart.db:/app/novacart.db" \
  novacart-backend

Note -- here we are passing db (mysql lite as volume which takes the local destination while adding ) so any DB changes will be applied to the local file as well which helps us to get persistent data 
and .env file to pass DB url (DB should be created first else first run the main.py locally to create one)

front end - 
Choosed nginx because light weight ,added new file nginx.conf which accepts the backend server request over the docker network we created for this .

location /api/ {
        proxy_pass http://backend:8000/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

frontend container start command - 
docker run -d --name frontend --network novacart-net -p 8080:80 novacart-frontend 



trade off - 

we need to restart both containers if any one got changes .