insert into customer (id, name, email) values (1, 'Matt', 'm@example.com') on conflict (id) do update set name = excluded.name, email = excluded.email returning id, name;
