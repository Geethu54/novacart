once cloned the repo create .env file 

things to add to the file 
APP_ENV=development
API_VERSION=v1
POSTGRES_USER=novacart
POSTGRES_PASSWORD=<change@123>
POSTGRES_DB=novacart

start the everything -
docker compose up --build -d

stop everything including db - 

docker compose down -v

restarting individual services 
docker compose restart backend      # restart just the backend
docker compose restart frontend     # restart just the frontend
docker compose restart postgres     # restart just the database


explanation -

Compose file spins up 3 services postgres (DB ) ,Frontend , Backend in networks forntend-net ,backend-net 

postgres lives in backend-net ,frontend in frontend-net , backend has communication to front-net  and backen-net this is to isolate database only backend can access the database not forntend .

databse env variables are passed using .env files which gets embedded in environment variables (we can switch db by changing .env no need to change the code for each environment)
 and backend depends on database in order to stop the container exiting used healthcheck to make sure postgres is alive .