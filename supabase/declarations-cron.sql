-- Keep automatic completion current even while no one has the site open.
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;
select cron.schedule('ward-declaration-completions','* * * * *','select public._decl_refresh(year) from public.declaration_seasons;');
