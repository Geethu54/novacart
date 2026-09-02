# NovaCart application handover

The development team has handed this repository to the DevOps team.

## Components
- `frontend/`: browser UI.
- `backend/`: FastAPI API.
- The application is expected to run on PostgreSQL in the cohort environment.

## Local developer run (without containers)
The backend can run with its SQLite fallback for developer convenience:

```bash
cd backend
python -m uvicorn app.main:app --host 0.0.0.0 --port 8080
```

Open frontend/index.html directly in your browser (file://). Do not start a separate frontend development/web server for this initial local run.

Use the application source as the source of truth for runtime details such as ports, health endpoints, environment variables, and persistence behavior.

## Team boundary
Application feature development is owned by the development team. Deployment, source-control workflow, containerization, CI, runtime configuration, and operational readiness are owned by the DevOps cohort.