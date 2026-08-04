-- Cambia el umbral visible del mensajero de 30 a 15 dias sin alterar el router seguro.
do $$
declare f text;
begin
  select pg_get_functiondef('public.api_buscar_activo(jsonb)'::regprocedure) into f;
  f := regexp_replace(f, 'dias\s*<=\s*30', 'dias <= 15', 'g');
  execute f;
end $$;

-- Incluye proximos vencimientos en alertas de registro/exportable.
do $$
declare f text;
begin
  select pg_get_functiondef('public.api_guardar_registro(jsonb)'::regprocedure) into f;
  if position('SOAT proximo a vencer' in f) = 0 then
    f := regexp_replace(f,
      '(alertas_doc\s*:=\s*alertas_doc\s*\|\|\s*''SOAT vencido el ''[^;]+;)',
      E'\\1\n  elsif coalesce(v_soat_v, c.soat_vence) <= hoy + 15 then\n    alertas_doc := alertas_doc || ''SOAT proximo a vencer el '' || to_char(coalesce(v_soat_v, c.soat_vence),''YYYY-MM-DD'') || '' | '';');
    f := regexp_replace(f,
      '(alertas_doc\s*:=\s*alertas_doc\s*\|\|\s*''Tecnomecanica vencida el ''[^;]+;)',
      E'\\1\n  elsif coalesce(v_tecno_v, c.tecnomecanica_vence) <= hoy + 15 then\n    alertas_doc := alertas_doc || ''Tecnomecanica proxima a vencer el '' || to_char(coalesce(v_tecno_v, c.tecnomecanica_vence),''YYYY-MM-DD'') || '' | '';');
    f := regexp_replace(f,
      '(alertas_doc\s*:=\s*alertas_doc\s*\|\|\s*''Licencia vencida el ''[^;]+;)',
      E'\\1\n  elsif coalesce(v_lic_v, c.licencia_vence) <= hoy + 15 then\n    alertas_doc := alertas_doc || ''Licencia proxima a vencer el '' || to_char(coalesce(v_lic_v, c.licencia_vence),''YYYY-MM-DD'') || '' | '';');
    if position('SOAT proximo a vencer' in f) = 0 then
      raise exception 'No se pudo localizar el bloque de alertas de api_guardar_registro';
    end if;
    execute f;
  end if;
end $$;
