FROM nginx:1.27-alpine

RUN rm -rf /usr/share/nginx/html/*

COPY index.html app.js styles.css /usr/share/nginx/html/

COPY nginx.conf.template /etc/nginx/templates/default.conf.template

# Local/docker-compose default so `docker build && docker run` keeps working
# unchanged; Azure Container Apps overrides this with the backend Container
# App's internal FQDN (see infra/azure).
ENV BACKEND_INTERNAL_URL=http://backend:8000

EXPOSE 80
 
CMD ["nginx", "-g", "daemon off;"]