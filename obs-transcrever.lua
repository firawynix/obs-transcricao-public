--[[
    obs-transcrever.lua

    Quando a gravacao para, dispara em segundo plano a transcricao do arquivo
    gravado. O texto sai como .txt e .srt na mesma pasta do video.

    Instalar em: Ferramentas > Scripts > (+)
]]

obs = obslua

-- script_path() e a pasta deste .lua: funciona de qualquer lugar que instalarem
local JANELA = script_path() .. "transcrever-console.ps1"
local APP = script_path() .. "Transcrever-Video.exe"
local ativo = true
local idioma = "pt"
local modo = "perguntar"     -- perguntar | direto
local cpu_max = 70
local legenda = true         -- embutir a legenda dentro do proprio video

local function existe(caminho)
    local f = io.open(caminho, "rb")
    if f == nil then return false end
    f:close()
    return true
end

local function transcrever(caminho, manual)
    if caminho == nil or caminho == "" then
        obs.script_log(obs.LOG_WARNING, "[transcricao] nenhum arquivo de gravacao encontrado")
        return
    end

    -- Interface grafica com progresso, intervalo, repeticoes, estimativa e pausa.
    -- No modo direto ela abre e comeca; no modo perguntar deixa revisar as opcoes.
    local perguntar = (not manual) and modo == "perguntar"
    local cmd
    if existe(APP) then
        cmd = string.format(
            'start "" "%s" "%s" --cpu %d --idioma %s%s%s',
            APP, caminho, cpu_max, idioma,
            perguntar and "" or " --iniciar",
            legenda and "" or " --sem-legenda")
    else
        -- compatibilidade com instalacoes antigas, antes do aplicativo grafico
        cmd = string.format(
            'start "" powershell -NoProfile -ExecutionPolicy Bypass -File "%s" -Video "%s"%s -CpuMax %d -Idioma %s%s',
            JANELA, caminho, perguntar and " -Perguntar" or "", cpu_max, idioma,
            legenda and "" or " -SemLegenda")
    end

    obs.script_log(obs.LOG_INFO, "[transcricao] enfileirado: " .. caminho)
    os.execute(cmd)
end

local function on_event(event)
    if not ativo then return end

    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        transcrever(obs.obs_frontend_get_last_recording())
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
        transcrever(obs.obs_frontend_get_last_replay())
    end
end

local function botao_agora(props, p)
    transcrever(obs.obs_frontend_get_last_recording(), true)
    return false
end

function script_description()
    return [[<b>Transcricao automatica das gravacoes</b><br/><br/>
    Ao parar a gravacao, gera <b>.txt</b> e <b>.srt</b> na mesma pasta do video
    (e <b>- falas.txt</b> se for reuniao, com quem falou o que).<br/><br/>
    A legenda com o nome de quem fala ja abre ligada no player. Para ligar/desligar,
    atalho <b>Legenda liga-desliga</b> na area de trabalho.<br/><br/>
    Abre um aplicativo com <b>andamento, tempo estimado, meta de duracao e pausa</b>.
    O processador fica limitado ao teto escolhido aqui embaixo.]]
end

function script_properties()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_bool(props, "ativo", "Transcrever automaticamente ao parar a gravacao")

    local mo = obs.obs_properties_add_list(props, "modo", "Ao parar a gravacao",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(mo, "Perguntar se quero transcrever", "perguntar")
    obs.obs_property_list_add_string(mo, "Transcrever direto, sem perguntar", "direto")

    local lista = obs.obs_properties_add_list(props, "idioma", "Idioma",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(lista, "Portugues (PT-BR)", "pt")
    obs.obs_property_list_add_string(lista, "Ingles", "en")
    obs.obs_property_list_add_string(lista, "Espanhol", "es")
    obs.obs_property_list_add_string(lista, "Detectar automaticamente", "auto")

    obs.obs_properties_add_int_slider(props, "cpu_max", "Teto de processador (%)", 20, 95, 5)

    obs.obs_properties_add_bool(props, "legenda", "Embutir a legenda dentro do proprio video")

    obs.obs_properties_add_button(props, "agora", "Transcrever a ultima gravacao agora", botao_agora)
    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "ativo", true)
    obs.obs_data_set_default_string(settings, "idioma", "pt")
    obs.obs_data_set_default_string(settings, "modo", "perguntar")
    obs.obs_data_set_default_int(settings, "cpu_max", 70)
    obs.obs_data_set_default_bool(settings, "legenda", true)
end

function script_update(settings)
    ativo = obs.obs_data_get_bool(settings, "ativo")
    idioma = obs.obs_data_get_string(settings, "idioma")
    modo = obs.obs_data_get_string(settings, "modo")
    cpu_max = obs.obs_data_get_int(settings, "cpu_max")
    legenda = obs.obs_data_get_bool(settings, "legenda")
end

function script_load(settings)
    obs.obs_frontend_add_event_callback(on_event)
end


