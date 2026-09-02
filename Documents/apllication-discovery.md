ticket -1
Application components - Has java script front end ,Backend is Python ,DB is postgres on prod  ,(SQL lite for local or dev)
* Languages and frameworks - python bakend, FastAPI framework , frontend java script ,HTML,CSS
* Startup/build commands - python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 (runs on 8000 port)
* Listening ports - database -5432, webserver - 443 (from internet to the entrypoint) , internal communication 8000(fastapi default )
* Application dependencies - need webserver
* Configuration and environment variables - requirements and environmental vairaibles like DB credentials
* Secrets or sensitive configuration - DB credentials stored in vault
* Persistence requirements - live catlog updates (db data)
* Database dependencies -
* Health and readiness behavior - get health ,get ready
* Service-to-service communication - one server handled bu reverse proxy

----------------------------
Components to be deployed  -
loadbalancer ,PVt subents
Server with webservers connection to both frontend and back end (reverse proxy will be better to protect the backend servers identity)
Database -postgresql
config requirements  - web server routing  , DB credentials

persistent data  - Postgres tables (need to be updated as per our orders ) ,fornt end is static
health checks - api calls /health for website avilabilty , /ready -check DB conenctions
missing info - how are we planned to eploy this prod (single server, multi server)