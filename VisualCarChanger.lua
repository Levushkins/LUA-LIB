--[[
           _
          | |
       ___| |__   __ _ _ __   ___
      / __| '_ \ / _` | '_ \ / _ \
     | (__| | | | (_| | |_) | (_) |
      \___|_| |_|\__,_| .__/ \___/
                      | |
                      |_|
    https://www.blast.hk/members/112329/

    VisualCarChanger 2.0
    Список личного транспорта берётся из CEF-меню /cars (пакет 220).
]]

script_name('VisualCarChanger')
script_author('chapo')
script_version('2.0')

local imgui = require 'imgui'
local encoding = require 'encoding'
encoding.default = 'CP1251'
u8 = encoding.UTF8
local sampev = require 'lib.samp.events'

local window = imgui.ImBool(false)

local tag = '{698cc7}[VisualCarChanger]: {ffffff}'
local vehs = {
    {'[ARZ] gtsamg', 612},
    {'[ARZ] g63amg', 613},
    {'[ARZ] rs6', 614},
    {'[ARZ] bmwxfive', 662},
    {'[ARZ] chevcor', 663},
    {'[ARZ] checruz', 665},
    {'[ARZ] lexlx', 666},
    {'[ARZ] porche911', 667},
    {'[ARZ] pcayenne', 668},
    {'[ARZ] bentley', 699},
    {'[ARZ] bmwm8', 793},
    {'[ARZ] e63', 794},
    {'[ARZ] merss63', 909},
    {'[ARZ] tuareg', 965},
    {'[ARZ] urus', 1194},
    {'[ARZ] aqeight', 1195},
    {'[ARZ] dodgcha', 1196},
    {'[ARZ] acurnsx', 1197},
    {'[ARZ] volvov', 1198},
    {'[ARZ] rangrove', 1199},
    {'[ARZ] civtr', 1200},
    {'[ARZ] lexis', 1201},
    {'[ARZ] mustang', 1202},
    {'[ARZ] volvoxc', 1203},
    {'[ARZ] jagfp', 1204},
    {'[ARZ] optima', 1205},
    {'[ARZ] bmwzf', 3155},
    {'[ARZ] kaban', 3156},
    {'[ARZ] bmwxf', 3157},
    {'[ARZ] ngtr34', 3158},
    {'[ARZ] diavel', 3194},
    {'[ARZ] ducati', 3195},
    {'[ARZ] ducnaked', 3196},
    {'[ARZ] zx10rr', 3197},
    {'[ARZ] western', 3198},
    {'[ARZ] rr', 3199},
    {'[ARZ] beetle', 3200},
    {'[ARZ] bugdivo', 3201},
    {'[ARZ] chiron', 3202},
    {'[ARZ] fiat500', 3203},
    {'[ARZ] gls2020', 3204},
    {'[ARZ] huntold', 3205},
    {'[ARZ] lambsvj', 3206},
    {'[ARZ] landsva', 3207},
    {'[ARZ] bmw530i', 3208},
    {'[ARZ] mbw221', 3209},
    {'[ARZ] modelx', 3210},
    {'[ARZ] nisleaf', 3211},
    {'[ARZ] nssilvia', 3212},
    {'[ARZ] sbforest', 3213},
    {'[ARZ] sblegasy', 3215},
    {'[ARZ] sonata', 3216},
    {'[ARZ] bmwe38', 3217},
    {'[ARZ] mbe55', 3218},
    {'[ARZ] mbe500', 3219},
    {'[ARZ] jstorm', 3220},
    {'[ARZ] lighmcq', 3222},
    {'[ARZ] mater', 3223},
    {'[ARZ] buckingham', 3224},
    {'[ARZ] infinity', 3232},
    {'[ARZ] lexrx', 3233},
    {'[ARZ] sportage', 3234},
    {'[ARZ] vwgolf', 3235},
    {'[ARZ] audir8', 3236},
    {'[ARZ] camry', 3237},
    {'[ARZ] cumry', 3238},
    {'[ARZ] m5e60', 3239},
    {'[ARZ] m5f90', 3240},
    {'[ARZ] maybach', 3245},
    {'[ARZ] mbamggt', 3247},
    {'[ARZ] panamera', 3248},
    {'[ARZ] passat', 3251},
    {'[ARZ] corvett1980', 3254},
    {'[ARZ] dodgesrt', 3266},
    {'[ARZ] gt500', 3348},
    {'[ARZ] amdb5', 3974},
    {'[ARZ] m3gtr', 4542},
    {'[ARZ] camaros', 4543},
    {'[ARZ] mrx7', 4544},
    {'[ARZ] mrx8', 4545},
    {'[ARZ] eclipse', 4546},
    {'[ARZ] mustold', 4547},
    {'[ARZ] n350z', 4548},
    {'[ARZ] 760li', 4774},
    {'[ARZ] one77', 4775},
    {'[ARZ] bacalars', 4776},
    {'[ARZ] bentayga', 4777},
    {'[ARZ] m4comp', 4778},
    {'[ARZ] bmwi8', 4779},
    {'[ARZ] gg90', 4780},
    {'[ARZ] intergenh', 4781},
    {'[ARZ] m3g20', 4782},
    {'[ARZ] s500w223', 4783},
    {'[ARZ] f150r', 4784},
    {'[ARZ] frj50', 4785},
    {'[ARZ] slr', 4786},
    {'[ARZ] subbrzz', 4787},
    {'[ARZ] swcross', 4788},
    {'[ARZ] taycan', 4789},
    {'[ARZ] twfer', 4790},
    {'[ARZ] uazpatriot', 4791},
    {'[ARZ] volga', 4792},
    {'[ARZ] xclass', 4793},
    {'[ARZ] xfrr2012', 4794},
    {'[ARZ] rcshutle', 4795},
    {'[ARZ] doddcar', 4796},
    {'[ARZ] crtsrt', 4797},
    {'[ARZ] fordexp', 4798},
    {'[ARZ] frd150', 4799},
    {'[ARZ] dltplan', 4800},
    {'[ARZ] seashark', 4801},
    {'[ARZ] copavent', 4802},
    {'[ARZ] amalfim90', 4803},
    {'[ARZ] audia6', 6604},
    {'[ARZ] audiq7', 6605},
    {'[ARZ] bmwm6', 6606},
    {'[ARZ] bnwm6', 6607},
    {'[ARZ] cla46', 6608},
    {'[ARZ] cls', 6609},
    {'[ARZ] haval', 6610},
    {'[ARZ] lc200', 6611},
    {'[ARZ] lincol', 6612},
    {'[ARZ] macan', 6613},
    {'[ARZ] matiz', 6614},
    {'[ARZ] mb6x6', 6615},
    {'[ARZ] mbe63', 6616},
    {'[ARZ] monster1', 6617},
    {'[ARZ] monster2', 6618},
    {'[ARZ] monster3', 6619},
    {'[ARZ] monster4', 6620},
    {'[ARZ] prado', 6621},
    {'[ARZ] rav4', 6622},
    {'[ARZ] supa90', 6623},
    {'[ARZ] uazold', 6624},
    {'[ARZ] xc90', 6625},
    {'[ARZ] r8bgft', 6650},
    {'[ARZ] bveyron', 6673},
    {'[ARZ] cente', 6674},
    {'[ARZ] rbronco', 6675},
    {'[ARZ] srubicon', 6676},
    {'[ARZ] mitsupaj3', 6677},
    {'[ARZ] bmwm3g80', 6678},
    {'[ARZ] bmwx3e83', 6679},
    {'[ARZ] ghostrll', 6680},
    {'[ARZ] shaman', 6681},
    {'[ARZ] lambtouch', 6682},
    {'[ARZ] amggtr', 6683},
    {'[ARZ] hummerh2', 6684},
    {'[ARZ] mitsuevo8', 6685},
    {'[ARZ] amggtbs', 6686},
    {'[ARZ] cls55', 6687},
    {'[ARZ] jmcholiday', 6693},
    {'[ARZ] uralponch', 6709},
    {'[ARZ] asx', 6710},
    {'[ARZ] alpinae34', 6711},
    {'[ARZ] x548i', 6712},
    {'[ARZ] ahonda', 6713},
    {'[ARZ] techinca', 6714},
    {'[ARZ] l100', 6715},
    {'[ARZ] dlanos6x6', 6716},
    {'[ARZ] w211', 6717},
    {'[ARZ] nss14', 6718},
    {'[ARZ] uralscoob', 6720},
    {'[ARZ] uralslender', 6733},
    {'[ARZ] moutlander', 6741},
    {'[ARZ] fantom', 6742},
    {'[ARZ] nss13', 6743},
    {'[ARZ] supra', 6744},
    {'[ARZ] tank', 6745},
    {'[ARZ] ultrarank', 6746},
    {'[ARZ] huracanpt', 6788},
    {'[ARZ] dodgchapir', 6789},
    {'[ARZ] uralwdnsdy', 6824},
    {'[ARZ] mackpacker', 6830},
    {'[ARZ] apie', 6835},
    {'[ARZ] bmwxmof', 6842},
    {'[ARZ] bmwxm', 6848},
    {'[ARZ] p992offroad', 6860},
    {'[ARZ] s500w223bwd', 7396},
    {'[ARZ] tanarg912', 7408},
    {'[ARZ] aerostar700', 7976},
    {'[ARZ] furat3', 9196},
    {'[ARZ] ftrailert3', 9197},
    {'[ARZ] hearsewdnsdy', 9199},
    {'[ARZ] airsht3', 9200},
    {'[ARZ] ecto1', 9268},
    {'[ARZ] esciq', 11773},
    {'[ARZ] bellfcx', 11785},
    {'[ARZ] jackdog', 11816},
    {'[ARZ] scaniach', 11818},
    {'[ARZ] panthr6x6', 11819},
    {'[ARZ] nsky34', 11820},
    {'[ARZ] mmc20', 11821},
    {'[ARZ] mgtny25', 11823},
    {'[ARZ] mersml350', 11824},
    {'[ARZ] mcsen', 11825},
    {'[ARZ] mb190et', 11826},
    {'[ARZ] mb190e', 11827},
    {'[ARZ] kmzdakar', 11828},
    {'[ARZ] mmc20m', 11829},
    {'[ARZ] brbsgts', 11831},
    {'[ARZ] bentleygt3', 11832},
    {'[ARZ] minicm', 11860},
    {'[ARZ] dcd24', 11866},
    {'[ARZ] roverh', 12101},
    {'[ARZ] bmwx5h', 12102},
    {'[ARZ] mersml350h', 12103},
    {'[ARZ] pg407taxi', 12173},
    {'[ARZ] gr86', 12267},
    {'[ARZ] ct5v', 12268},
    {'[ARZ] p964', 12271},
    {'[ARZ] vetc5', 12279},
    {'[ARZ] lavoi', 12280},
    {'[ARZ] spchaos', 12281},
    {'[ARZ] brtsbank', 12282},
    {'[ARZ] towraptor', 12285},
    {'[ARZ] xpenght', 12338},
    {'[ARZ] frd450road', 12339},
    {'[ARZ] ntravel', 12340},
    {'[ARZ] ducati1199', 12341},
    {'[ARZ] kmztyph', 12342},
    {'[ARZ] paz3205', 12343},
    {'[ARZ] vaz2101', 12344},
    {'[ARZ] cbvaz2101', 12345},
    {'[ARZ] senat', 12346},
    {'[ARZ] 2107ofr', 12347},
    {'[ARZ] mbcheqsuv', 12348},
    {'[ARZ] landelevo', 12349},
    {'[ARZ] lucidair', 12350},
    {'[ARZ] corollagr', 12351},
    {'[ARZ] lc500c', 12352},
    {'[ARZ] corvettec8', 12353},
    {'[ARZ] mclspeed', 12354},
    {'[ARZ] ct7pm', 12355},
    {'[ARZ] vestas', 12356},
    {'[ARZ] tcelicagt', 12357},
    {'[ARZ] sf90', 12358},
    {'[ARZ] transam', 12359},
    {'[ARZ] bentayga24', 12360},
    {'[ARZ] bentp750', 12361},
    {'[ARZ] kawh2r', 12362},
    {'[ARZ] bmwg90', 12363},
    {'[ARZ] xpengfly', 12389},
    {'[ARZ] pg407', 12391},
    {'[ARZ] trakker500', 12393},
    {'[ARZ] suprafnf', 12397},
    {'[ARZ] uaz', 12440},
    {'[ARZ] uruspir', 12441},
    {'[ARZ] evo9tt', 12442},
    {'[ARZ] volgatti', 12443},
    {'[ARZ] chevcorfbi', 12444},
    {'[ARZ] rtrfbi', 12445},
    {'[ARZ] uaehuracan', 12446},
    {'[ARZ] crocobomb', 12447},
    {'[ARZ] gnx', 12448},
    {'[ARZ] bkrr79', 12449},
    {'[ARZ] cdeville', 12450},
    {'[ARZ] cbelair', 12451},
    {'[ARZ] chevmc78', 12452},
    {'[ARZ] f12c', 12501},
    {'[ARZ] fporto', 12526},
    {'[ARZ] vetc5sc', 12536},
    {'[ARZ] mitsuhsr', 12537},
    {'[ARZ] x100mk2', 12538},
    {'[ARZ] csilverado', 12598},
    {'[ARZ] lveneno', 12599},
    {'[ARZ] lincnav', 12600},
    {'[ARZ] merceqc', 12601},
    {'[ARZ] phuayra', 12602},
    {'[ARZ] rrbt', 12603},
    {'[ARZ] arteon', 12604},
    {'[ARZ] inspireint', 12605},
    {'[ARZ] sgrin', 12606},
    {'[ARZ] ssanta', 12607},
    {'[ARZ] f250gto', 12611},
    {'[ARZ] mgts18', 12613},
    {'[ARZ] pphv', 12614},
    {'[ARZ] rickandmortycar', 12615},
    {'[ARZ] skdkodiaq', 12616},
    {'[ARZ] amdbs18', 12622},
    {'[ARZ] bfspur', 12623},
    {'[ARZ] buran', 12624},
    {'[ARZ] ggti', 12625},
    {'[ARZ] guliaqv', 12626},
    {'[ARZ] ioniq5', 12627},
    {'[ARZ] m2g87', 12628},
    {'[ARZ] mizu', 12630},
    {'[ARZ] s1snowmobile', 12631},
    {'[ARZ] skodaokt', 12632},
    {'[ARZ] wrng24', 12633},
    {'[ARZ] madgaz', 12684},
    {'[ARZ] lmzhw', 12685},
    {'[ARZ] hwbus', 12686},
    {'[ARZ] giga', 12687},
    {'[ARZ] mersgl', 12713},
    {'[ARZ] laguna', 12714},
    {'[ARZ] mercls', 12715},
    {'[ARZ] audirs5', 12716},
    {'[ARZ] cadesc', 12717},
    {'[ARZ] cybertr', 12718},
    {'[ARZ] modelc', 12719},
    {'[ARZ] fordgt', 12720},
    {'[ARZ] dviper', 12721},
    {'[ARZ] vwpolo', 12722},
    {'[ARZ] evoix', 12723},
    {'[ARZ] ttrs', 12724},
    {'[ARZ] actros', 12725},
    {'[ARZ] aus4', 12726},
    {'[ARZ] bmw4s', 12727},
    {'[ARZ] cadesc07', 12728},
    {'[ARZ] chaser', 12729},
    {'[ARZ] dacia', 12730},
    {'[ARZ] evox', 12731},
    {'[ARZ] impla64', 12732},
    {'[ARZ] impla67', 12733},
    {'[ARZ] kenwooth', 12734},
    {'[ARZ] kenwtrl', 12735},
    {'[ARZ] macmp4', 12736},
    {'[ARZ] mustm1', 12737},
    {'[ARZ] phantom', 12738},
    {'[ARZ] picup', 12739},
    {'[ARZ] volvotr', 12740},
    {'[ARZ] wrxsti', 12741},
    {'[ARZ] sherp', 12742},
    {'[ARZ] sanki', 12743},
    {'[ARZ] frankym', 12767},
    {'[ARZ] evil', 12768},
    {'[ARZ] bdelihw', 12769},
    {'[ARZ] eastertruck', 13948},
    {'[ARZ] monowheel', 14031},
    {'[ARZ] lpbmw30', 14058},
    {'[ARZ] lpfef40', 14059},
    {'[ARZ] lpmurciela', 14060},
    {'[ARZ] lpw124', 14061},
    {'[ARZ] lpkart', 14062},
    {'[ARZ] uruskart', 14063},
    {'[ARZ] jesko', 14064},
    {'[ARZ] mbolph', 14065},
    {'[ARZ] bugatl', 14066},
    {'[ARZ] camarozl1', 14067},
    {'[ARZ] escaladeiq', 14068},
    {'[ARZ] kiamoha', 14069},
    {'[ARZ] gffwht', 14070},
    {'[ARZ] bmwx7l', 14071},
    {'[ARZ] gelencart', 14072},
    {'[ARZ] cybermans', 14073},
    {'[ARZ] koenig1', 14074},
    {'[ARZ] 4runner', 14086},
    {'[ARZ] mustrtr', 14087},
    {'[ARZ] sleighezch', 14111},
    {'[ARZ] snouboard_invis', 14118},
    {'[ARZ] a6krsh', 14119},
    {'[ARZ] cumkrsh', 14120},
    {'[ARZ] kiakarsh', 14121},
    {'[ARZ] modxkrsh', 14122},
    {'[ARZ] rav4krsh', 14123},
    {'[ARZ] gtr2017', 14124},
    {'[ARZ] codalunga', 14131},
    {'[ARZ] mersw116', 14132},
    {'[ARZ] offe34', 14133},
    {'[ARZ] eighbus', 14134},
    {'[ARZ] merst', 14135},
    {'[ARZ] merstourismo', 14137},
    {'[ARZ] volvofh12', 14138},
    {'[ARZ] mackanthem', 14139},
    {'[ARZ] semi', 14140},
    {'[ARZ] westernd', 14141},
    {'[ARZ] businesj', 14142},
    {'[ARZ] jet60', 14143},
    {'[ARZ] sairplane', 14145},
    {'[ARZ] aur8dr', 14193},
    {'[ARZ] dodangie', 14194},
    {'[ARZ] frdmrzr', 14195},
    {'[ARZ] rezvani', 14221},
    {'[ARZ] peterbilt359', 14242},
    {'[ARZ] s30z', 14244},
    {'[ARZ] bcentodieci', 14245},
    {'[ARZ] cadesc23', 14246},
    {'[ARZ] prsng', 14247},
    {'[ARZ] huracan', 14248},
    {'[ARZ] huracanst', 14249},
    {'[ARZ] urusoff', 14250},
    {'[ARZ] sf90ofroad', 14251},
    {'[ARZ] plygtx', 14252},
    {'[ARZ] 427custom', 14253},
    {'[ARZ] meclipse', 14254},
    {'[ARZ] cadlarte', 14255},
    {'[ARZ] skate1', 14281},
    {'[ARZ] airship', 14338},
    {'[ARZ] rcmavic', 14355},
    {'[ARZ] amgone', 14767},
    {'[ARZ] valkyrie', 14768},
    {'[ARZ] aveo', 14769},
    {'[ARZ] bugbol', 14857},
    {'[ARZ] buggys', 14884},
    {'[ARZ] duster', 14899},
    {'[ARZ] monza', 14904},
    {'[ARZ] g630', 14905},
    {'[ARZ] hotwheels', 14906},
    {'[ARZ] humhx', 14907},
    {'[ARZ] laferr', 14908},
    {'[ARZ] m5cs', 14909},
    {'[ARZ] priora', 14910},
    {'[ARZ] quadra', 14911},
    {'[ARZ] gle', 14912},
    {'[ARZ] vision', 14913},
    {'[ARZ] mntnbike', 14914},
    {'[ARZ] mntnbike2', 14915},
    {'[ARZ] mtbbik', 14916},
    {'[ARZ] scrcher', 14917},
    {'[ARZ] autobus1', 14918},
    {'[ARZ] autobus2', 14919},
    {'[ARZ] airsht1', 14921},
    {'[ARZ] airsht2', 14922},
    {'[ARZ] furat1', 14923},
    {'[ARZ] ftrailert1', 14942},
    {'[ARZ] furat2', 14943},
    {'[ARZ] ftrailert2', 14944},
    {'[ARZ] mcl570stun', 14954},
    {'[ARZ] shorty', 14968},
    {'[ARZ] charger', 15085},
    {'[ARZ] m1e26', 15098},
    {'[ARZ] countach', 15099},
    {'[ARZ] nagasaki', 15100},
    {'[ARZ] gemera', 15101},
    {'[ARZ] kiak7', 15102},
    {'[ARZ] toro', 15103},
    {'[ARZ] lx600', 15104},
    {'[ARZ] qashai', 15105},
    {'[ARZ] predatorr', 15106},
    {'[ARZ] scirroco', 15107},
    {'[ARZ] longfin', 15108},
    {'[ARZ] toyotagr', 15109},
    {'[ARZ] wellcraft', 15110},
    {'[ARZ] yacht', 15111},
    {'[ARZ] boates', 15112},
    {'[ARZ] a45', 15113},
    {'[ARZ] ae86', 15114},
    {'[ARZ] defender', 15115},
    {'[ARZ] mach', 15116},
    {'[ARZ] mazda6', 15117},
    {'[ARZ] r8s', 15118},
    {'[ARZ] santafe', 15119},
    {'[ARZ] monoarmy', 15168},
    {'[ARZ] ktank', 15169},
    {'[ARZ] 180itasha', 15170},
    {'[ARZ] mbg63army', 15171},
    {'[ARZ] x5g05', 15197},
    {'[ARZ] slngshot', 15198},
    {'[ARZ] f150rmon', 15234},
    {'[ARZ] ferlcycle', 15235},
    {'[ARZ] ff80', 15236},
    {'[ARZ] ftwc', 15237},
    {'[ARZ] gbcar', 15238},
    {'[ARZ] hwfbed', 15239},
    {'[ARZ] lbsian', 15240},
    {'[ARZ] sfuaz', 15241},
    {'[ARZ] wmoto', 15242},
    {'[ARZ] wowgyro', 15243},
    {'[ARZ] wowrod', 15244},
    {'[ARZ] xisu7', 15245},
    {'[ARZ] tourbillion', 15255},
    {'[ARZ] mc720stc', 15257},
    {'[ARZ] froman', 15258},
    {'[ARZ] cdevillepir', 15270},
    {'[ARZ] pbus', 15271},
    {'[ARZ] tundpir', 15272},
    {'[ARZ] nisvgt', 15273},
    {'[ARZ] srttoma', 15274},
    {'[ARZ] sf6k', 15275},
    {'[ARZ] zenst1', 15276},
    {'[ARZ] zondafrd', 15277},
    {'[ARZ] am20k', 15278},
    {'[ARZ] volgsf', 15279},
    {'[ARZ] jeepamp', 15280},
    {'[ARZ] bt41r', 15281},
    {'[ARZ] scifitruck', 15282},
    {'[ARZ] mwcf', 15283},
    {'[ARZ] velar', 15295},
    {'[ARZ] mb1620', 15326},
    {'[ARZ] tc', 15327},
    {'[ARZ] constell', 15328},
    {'[ARZ] luxeplane', 15329},
    {'[ARZ] nimbus', 15330},
    {'[ARZ] kingc90b', 15331},
    {'[ARZ] arocs', 15332},
    {'[ARZ] iveco', 15333},
    {'[ARZ] man', 15334},
    {'[ARZ] volvo', 15335},
    {'[ARZ] vcambulan', 15416},
    {'[ARZ] vcbanshee', 15417},
    {'[ARZ] vcbenson', 15418},
    {'[ARZ] vcbloodra', 15419},
    {'[ARZ] vcbus', 15420},
    {'[ARZ] vccabbie', 15421},
    {'[ARZ] vccopcar', 15422},
    {'[ARZ] vcdeluxo', 15423},
    {'[ARZ] vcfbiranch', 15424},
    {'[ARZ] vcflatbed', 15425},
    {'[ARZ] vcidaho', 15426},
    {'[ARZ] vcinfernus', 15427},
    {'[ARZ] vclovefist', 15428},
    {'[ARZ] vcpatriot', 15429},
    {'[ARZ] vcpizzaboy', 15430},
    {'[ARZ] vcsecurica', 15431},
    {'[ARZ] vcsentinel', 15432},
    {'[ARZ] vcstinger', 15433},
    {'[ARZ] vcstretch', 15434},
    {'[ARZ] vctaxi', 15435},
    {'[ARZ] vctrash', 15436},
    {'[ARZ] uhunter', 15438},
    {'[ARZ] b900r', 15439},
    {'[ARZ] benefactor', 15442},
    {'[ARZ] cheerok', 15443},
    {'[ARZ] patriotm', 15444},
    {'[ARZ] veloceraptor', 15445},
    {'[ARZ] zen', 15446},
    {'[ARZ] amarokv6', 15449},
    {'[ARZ] bmwf82', 15451},
    {'[ARZ] bmwninetr', 15452},
    {'[ARZ] cturbogt', 15453},
    {'[ARZ] ev9', 15454},
    {'[ARZ] fbrick', 15455},
    {'[ARZ] li9', 15456},
    {'[ARZ] lotusem', 15457},
    {'[ARZ] vcangel', 15485},
    {'[ARZ] vcbfinject', 15486},
    {'[ARZ] vcblistac', 15487},
    {'[ARZ] vcburrito', 15488},
    {'[ARZ] vcfbicar', 15489},
    {'[ARZ] vchotrinb', 15490},
    {'[ARZ] vcsabre', 15491},
    {'[ARZ] vcsanchez', 15492},
    {'[ARZ] ambtess', 15493},
    {'[ARZ] ambtesx', 15494},
    {'[ARZ] bmwix', 15495},
    {'[ARZ] eqc', 15496},
    {'[ARZ] etron', 15497},
    {'[ARZ] ipace', 15498},
    {'[ARZ] charsrt', 15499},
    {'[ARZ] poltesx', 15500},
    {'[ARZ] twizy', 15501},
    {'[ARZ] polestar', 15502},
    {'[ARZ] fiat501', 15503},
    {'[ARZ] bmwg90n', 15514},
    {'[ARZ] sals7', 15517},
    {'[ARZ] lotv8', 15553},
    {'[ARZ] vitofire', 15554},
    {'[ARZ] narhc', 15555},
    {'[ARZ] ns15tune', 15556},
    {'[ARZ] rx7fddrift', 15558},
    {'[ARZ] sky32', 15559},
    {'[ARZ] frdexpfire', 15560},
    {'[ARZ] vanda', 15561},
    {'[ARZ] whplsh', 15562},
    {'[ARZ] fortbus', 15563},
    {'[ARZ] vivarodel', 15564},
    {'[ARZ] audirsq8m', 15565},
    {'[ARZ] 939rsr', 15566},
    {'[ARZ] p24rs911', 15568},
    {'[ARZ] xmmans', 15569},
    {'[ARZ] rrsm', 15572},
    {'[ARZ] madcar', 15605},
    {'[ARZ] peterbilt', 15618},
    {'[ARZ] pturbos', 15619},
    {'[ARZ] madtrain', 15620},
    {'[ARZ] volvo460', 15621},
    {'[ARZ] mbg163', 15626},
    {'[ARZ] bmw7srs', 15627},
    {'[ARZ] mbv250', 15628},
    {'[ARZ] mbc63', 15629},
    {'[ARZ] mbc63sc', 15630},
    {'[ARZ] audirs7', 15631},
    {'[ARZ] chevyc10', 15635},
    {'[ARZ] chevyc10p', 15653},
    {'[ARZ] gaz21', 15669},
    {'[ARZ] bmwi8glen', 15679},
    {'[ARZ] corvc1', 15708},
    {'[ARZ] barbie_cv', 15710},
    {'[ARZ] 280z', 15711},
    {'[ARZ] gmcinc', 15713},
    {'[ARZ] articts', 15720},
    {'[ARZ] mgle', 15721},
    {'[ARZ] modelthree', 15722},
    {'[ARZ] mucrelago', 15723},
    {'[ARZ] xoomer', 15724},
    {'[ARZ] jmc', 15725},
    {'[ARZ] humvee', 15730},
    {'[ARZ] impalaw', 15731},
    {'[ARZ] nsx90', 15733},
    {'[ARZ] mystery', 15734},
    {'[ARZ] nisan', 15742},
    {'[ARZ] bike_skull', 15743},
    {'[ARZ] seven', 15746},
    {'[ARZ] x6', 15747},
    {'[ARZ] gladiator', 15748},
    {'[ARZ] m8', 15749},
    {'[ARZ] toureg', 15750},
    {'[ARZ] rover', 15751},
    {'[ARZ] s63', 15752},
    {'[ARZ] uralnewyear', 15765},
    {'[ARZ] scifiufo', 15784},
    {'[ARZ] flybike', 15787},
    {'[ARZ] spcar4', 15788},
    {'[ARZ] snowkad', 15807},
    {'[ARZ] tronbike', 15822},
    {'[ARZ] hdchopper', 15829},
    {'[ARZ] c63', 15858},
    {'[ARZ] f10', 15859},
    {'[ARZ] e30', 15860},
    {'[ARZ] transporter', 15861},
    {'[ARZ] vito', 15862},
    {'[ARZ] vivaro', 15863},
    {'[ARZ] 2109n', 15870},
    {'[ARZ] amggt24', 15871},
    {'[ARZ] fbronco21', 15872},
    {'[ARZ] glcamg25', 15873},
    {'[ARZ] brtstock', 15874},
    {'[ARZ] hs2k', 15875},
    {'[ARZ] lada2114', 15876},
    {'[ARZ] m5sting', 15877},
    {'[ARZ] arcanataxi', 15878},
    {'[ARZ] e63taxi', 15879},
    {'[ARZ] fusiontaxi', 15880},
    {'[ARZ] s500w223t', 15881},
    {'[ARZ] skate', 15882},
    {'[ARZ] surfboard', 15883},
    {'[ARZ] cadesc23t', 15888},
    {'[ARZ] audi80', 15902},
    {'[ARZ] c63coupe', 15903},
    {'[ARZ] e34', 15904},
    {'[ARZ] e63w', 15905},
    {'[ARZ] f85', 15906},
    {'[ARZ] gallardo', 15907},
    {'[ARZ] gle2016', 15908},
    {'[ARZ] m8old', 15909},
    {'[ARZ] rs18', 15910},
    {'[ARZ] kmz', 15934},
    {'[ARZ] optimus_tr', 15935},
    {'[ARZ] twister', 15937},
    {'[ARZ] hot_rot_hell', 15942},
    {'[ARZ] hod_rod_hulk', 15943},
    {'[ARZ] dodsanki', 15956},
    {'[ARZ] nsky34tun', 15957},
    {'[ARZ] gt900', 15960},
    {'[ARZ] gbrabus', 15961},
    {'[ARZ] 720s', 15962},
    {'[ARZ] ram3500', 15963},
    {'[ARZ] helicopter', 15964},
    {'[ARZ] metla', 15965},
    {'[ARZ] betcars', 16793},
    {'[ARZ] bigben', 16794},
    {'[ARZ] cabine', 16795},
    {'[ARZ] postcar', 16796},
    {'[ARZ] retlook', 16797},
    {'[ARZ] freewayh', 16798},
    {'[ARZ] arkana', 16800},
    {'[ARZ] kvin', 16861},
    {'[ARZ] 2107', 16862},
    {'[ARZ] cloverbg', 16863},
    {'[ARZ] crvnvic', 16864},
    {'[ARZ] dsxtn', 16865},
    {'[ARZ] e53_amg_25', 16866},
    {'[ARZ] r35_10y', 16867},
    {'[ARZ] evo6_10y', 16868},
    {'[ARZ] fsf23', 16869},
    {'[ARZ] kawaxr10', 16870},
    {'[ARZ] ns15ss', 16872},
    {'[ARZ] nsx10y', 16873},
    {'[ARZ] lc200_fbi', 16874},
    {'[ARZ] dlanos', 16879},
    {'[ARZ] brag63a', 16892},
    {'[ARZ] s500w223b', 16893},
    {'[ARZ] 812mansory', 16894},
    {'[ARZ] bentaygam', 16895},
    {'[ARZ] gbrabus63', 16896},
    {'[ARZ] gmansory63', 16897},
    {'[ARZ] gls2020b', 16898},
    {'[ARZ] rrls', 16899},
    {'[ARZ] urusm', 16900},
    {'[ARZ] chevcoll', 16903},
    {'[ARZ] cadsev', 16904},
    {'[ARZ] tahoest', 16909},
    {'[ARZ] snouboard', 16920},
    {'[ARZ] bmwm3g81', 16932},
    {'[ARZ] hotprop', 16933},
    {'[ARZ] corvett', 16951},
    {'[ARZ] carrera', 16952},
    {'[ARZ] scramjet', 16953},
    {'[ARZ] dodgehell', 16954},
    {'[ARZ] f40', 16955},
    {'[ARZ] canis', 16956},
    {'[ARZ] tahoe', 16957},
    {'[ARZ] tmpagt', 16958},
    {'[ARZ] tundratrd', 16959},
    {'[ARZ] kalina', 16964},
    {'[ARZ] lada112', 16969},
    {'[ARZ] m20', 16970},
    {'[ARZ] nivas', 16971},
    {'[ARZ] nivaurban', 16972},
    {'[ARZ] el_scooter1', 16994},
    {'[ARZ] el_scooter2', 16995},
    {'[ARZ] el_scooter3', 16996},
    {'[ARZ] bmwi7', 18152},
    {'[ARZ] cobra', 18153},
    {'[ARZ] fusion', 18154},
    {'[ARZ] mark', 18155},
    {'[ARZ] nexia', 18156},
    {'[ARZ] passatb', 18157},
    {'[ARZ] iqx', 18158},
    {'[ARZ] sl63', 18159},
    {'[ARZ] titan', 18160},
    {'[ARZ] victoria', 18161},
    {'[ARZ] cheeta', 18164},
    {'[ARZ] huntleys', 18165},
    {'[ARZ] oneo', 18166},
    {'[ARZ] pegassi', 18167},
    {'ALPHA', 602},{'HUSTLER', 545},{'BLISTAC', 496},{'MAJESTC', 517},{'BRAVURA', 401},{'MANANA', 410},{'BUCCANE', 518},{'PICADOR', 600},{'CADRONA', 527},{'PREVION', 436},{'CLUB', 589},{'STAFFRD', 580},{'ESPERAN', 419},{'STALION', 439},{'FELTZER', 533},{'TAMPA', 549},{'FORTUNE', 526},{'VIRGO', 491},{'HERMES', 474},{'ADMIRAL', 445},{'OCEANIC', 467},{'GLENSHI', 604},{'PREMIER', 426},{'ELEGANT', 507},{'PRIMO', 547},{'EMPEROR', 585},{'SENTINL', 405},{'EUROS', 587},{'STRETCH', 409},{'GLENDAL', 466},{'SUNRISE', 550},{'GREENWO', 492},{'TAHOMA', 566},{'INTRUDR', 546},{'VINCENT', 540},{'MERIT', 551},{'WASHING', 421},{'NEBULA', 516},{'WILLARD', 529},{'ANDROM', 592},{'NEVADA', 553},{'AT400', 577},{'SANMAV', 488},{'BEAGLE', 511},{'POLMAV', 497},{'CARGOBB', 548},{'RAINDNC', 563},{'CROPDST', 512},{'RUSTLER', 476},{'DODO', 593},{'SEASPAR', 447},{'HUNTER', 425},{'SHAMAL', 519},{'HYDRA', 520},{'SKIMMER', 460},{'LEVIATH', 417},{'SPARROW', 469},{'MAVERIC', 487},{'STUNT', 513},{'BF400', 581},{'MTBIKE', 510},{'BIKE', 509},{'NRG500', 522},{'BMX', 481},{'PCJ600', 461},{'FAGGIO', 462},{'PIZZABO', 448},{'FCR900', 521},{'SANCHEZ', 468},{'FREEWAY', 463},{'WAYFARE', 586},{'COASTG', 472},{'DINGHY', 473},{'JETMAX', 493},{'LAUNCH', 595},{'MARQUIS', 484},{'PREDATR', 430},{'REEFER', 453},{'SPEEDER', 452},{'SQUALO', 446},{'TROPIC', 454},{'BAGGAGE', 485},{'UTILITY', 552},{'BUS', 431},{'CABBIE', 438},{'COACH', 437},{'SWEEPER', 574},{'TAXI', 420},{'TOWTRUK', 525},{'TRASHM', 408},{'AMBULAN', 416},{'POLICAR', 596},{'BARRCKS', 433},{'POLICAR', 597},{'ENFORCR', 427},{'RANGER', 599},{'FBIRANC', 490},{'RHINO', 432},{'FBITRUK', 528},{'SWATVAN', 601},{'FIRETRK', 407},{'SECURI', 428},{'FIRELA', 544},{'HPV1000', 523},{'PATRIOT', 470},{'POLICAR', 598},{'BENSON', 499},{'HOTDOG', 588},{'BOXBURG', 609},{'LINERUN', 403},{'BOXVILL', 498},{'PETROL', 514},{'CEMENT', 524},{'WHOOPEE', 423},{'COMBINE', 532},{'MULE', 414},{'DFT30', 578},{'PACKER', 443},{'DOZER', 486},{'RDTRAIN', 515},{'DUMPER', 406},{'TRACTOR', 531},{'DUNE', 573},{'YANKEE', 456},{'FLATBED', 455},{'TOPFUN', 459},{'SADLER', 543},{'BOBCAT', 422},{'TUG', 583},{'BURRITO', 482},{'WALTON', 478},{'SADLSHI', 605},{'YOSEMIT', 554},{'FORKLFT', 530},{'MOONBM', 418},{'MOWER', 572},{'NEWSVAN', 582},{'PONY', 413},{'RUMPO', 440},{'BLADE', 536},{'BROADWY', 575},{'REMING', 534},{'SAVANNA', 567},{'SLAMVAN', 535},{'TORNADO', 576},{'VOODOO', 412},{'BUFFALO', 402},{'CLOVER', 542},{'PHOENIX', 603},{'SABRE', 475},{'TRAM', 449},{'FREIGHT', 537},{'STREAK', 538},{'STREAKC', 570},{'RCBANDT', 441},{'RCBARON', 464},{'RCGOBLI', 501},{'RCRAIDE', 465},{'RCTIGER', 564},{'BANDITO', 568},{'MONSTB', 557},{'BFINJC', 424},{'QUAD', 471},{'BLOODRA', 504},{'SANDKIN', 495},{'CADDY', 457},{'VORTEX', 539},{'CAMPER', 483},{'JOURNEY', 508},{'KART', 571},{'MESAA', 500},{'MONSTER', 444},{'MONSTA', 556},{'BANSHEE', 429},{'INFERNU', 411},{'BULLET', 541},{'JESTER', 559},{'CHEETAH', 415},{'STRATUM', 561},{'COMET', 480},{'SULTAN', 560},{'ELEGY', 562},{'SUPERGT', 506},{'FLASH', 565},{'TURISMO', 451},{'HOTKNIF', 434},{'URANUS', 558},{'HOTRING', 494},{'WINDSOR', 555},{'HOTRINA', 502},{'ZR350', 477},{'HOTRINB', 503},{'HUNTLEY', 579},{'LANDSTK', 400},{'PEREN', 404},{'RANCHER', 489},{'RANCHER', 505},{'REGINA', 479},{'ROMERO', 442},{'SOLAIR', 458},{'BAGBOXA', 606},{'BAGBOXB', 607},{'FARMTR1', 610},{'FRBOX', 590},{'FRFLAT', 569},{'UTILTR1', 611},{'PETROTR', 584},{'TUGSTAI', 608},{'ARTICT1', 435},{'ARTICT2', 450},{'ARTICT3', 591},{'RCCAM', 594},
}

--==[ФАЙЛЫ]==--
local cfgDir     = getWorkingDirectory()..'\\config'
local file_repl  = cfgDir..'\\VisualCarChanger__replaces.json'   -- слот -> модель замены
local file_cars  = cfgDir..'\\VisualCarChanger__mycars.json'     -- кэш списка личного транспорта
local file_old   = cfgDir..'\\VisualCarChangerByChapo__newcars.json' -- старый формат (для миграции)

local function ensureCfgDir()
    if not doesDirectoryExist(cfgDir) then createDirectory(cfgDir) end
end

local function jsonSave(path, t)
    ensureCfgDir()
    local f = io.open(path, 'w')
    if not f then return false end
    f:write(encodeJson(t))
    f:flush()
    f:close()
    return true
end

local function jsonRead(path)
    if not doesFileExist(path) then return nil end
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    if not s or #s == 0 then return nil end
    local ok, t = pcall(decodeJson, s)
    if ok and type(t) == 'table' then return t end
    return nil
end

--==[ДАННЫЕ]==--
-- cars[slot] = {slot, title, status, sysName, vehid, plate}
local cars = {}
-- отсортированный по слоту список для отрисовки
local carsList = {}
-- replaces[slot] = {title = 'имя моей тачки', name = '[ARZ] urus', model = 1194}
local replaces = {}

local usedSlots, maxSlots = 0, 0
local carsDirty = false
local cefDebug = false

local function rebuildCarsList()
    carsList = {}
    for _, c in pairs(cars) do
        carsList[#carsList + 1] = c
    end
    table.sort(carsList, function(a, b) return a.slot < b.slot end)
end

local function saveCars()
    local t = {}
    for _, c in ipairs(carsList) do
        t[#t + 1] = c
    end
    jsonSave(file_cars, t)
end

local function loadCars()
    local t = jsonRead(file_cars)
    if not t then return end
    for _, c in pairs(t) do
        if type(c) == 'table' and tonumber(c.slot) then
            c.slot = tonumber(c.slot)
            c.vehid = tonumber(c.vehid)
            cars[c.slot] = c
        end
    end
    rebuildCarsList()
end

local function saveReplaces()
    local t = {}
    for slot, r in pairs(replaces) do
        t[tostring(slot)] = r
    end
    jsonSave(file_repl, t)
end

local function loadReplaces()
    local t = jsonRead(file_repl)
    if t then
        for k, v in pairs(t) do
            local slot = tonumber(k)
            if slot and type(v) == 'table' and tonumber(v.model) then
                replaces[slot] = {title = v.title, name = v.name, model = tonumber(v.model)}
            end
        end
        return
    end
    -- миграция со старого формата: массив {name, modelid}, индекс = позиция в диалоге /cars
    local old = jsonRead(file_old)
    if old then
        local migrated = 0
        for k, v in pairs(old) do
            local idx = tonumber(k)
            if idx and type(v) == 'table' and tonumber(v[2]) then
                replaces[idx - 1] = {title = nil, name = v[1], model = tonumber(v[2])}
                migrated = migrated + 1
            end
        end
        if migrated > 0 then
            saveReplaces()
            sampAddChatMessage(tag..'перенесено замен из старого конфига: {698cc7}'..migrated..'{ffffff}. Проверь список - нумерация слотов могла сдвинуться.', -1)
        end
    end
end

--==[CEF (пакет 220)]==--
-- 0    u8  - 220, ID пакета
-- 1    u8  - 17 = выполнить JS, 18 = событие CEF
-- 2-5  u32 - id браузера
-- 6-7  u16 - длина JS-строки (символов, CP1251)
-- 8-10 u8 + u16 - служебные поля
-- 11+  - строка, сжатая huffman-деревом SA-MP
local CEF_PACKET      = 220
local CEF_EXECUTE_JS  = 17
local CEF_EVENT       = 18

-- смещение строки в битах от начала суб-ID. Основной вариант - 80 (11-й байт пакета),
-- остальные на случай если Arizona поменяет заголовок.
local CEF_OFFSETS = {80, 56, 64, 72, 88, 96, 48}
local cefOffset = nil

local function cefDecodeJs(bs, base)
    raknetBitStreamSetReadOffset(bs, base + 8 + 32)
    local len = raknetBitStreamReadInt16(bs)
    if not len or len <= 0 or len > 60000 then return nil end
    local total = raknetBitStreamGetNumberOfBitsUsed(bs)
    local list = cefOffset and {cefOffset} or CEF_OFFSETS
    for _, off in ipairs(list) do
        if base + off < total then
            raknetBitStreamSetReadOffset(bs, base + off)
            local ok, str = pcall(raknetBitStreamDecodeString, bs, len + 1)
            if ok and type(str) == 'string' and str:find('executeEvent', 1, true) then
                if not cefOffset then cefOffset = off end
                return str
            end
        end
    end
    return nil
end

local function pushVehicleItems(json)
    local count = 0
    local pos = 1
    while true do
        local s = json:find('{"id":', pos, true)
        if not s then break end
        local e = json:find('{"id":', s + 6, true)
        local part = json:sub(s, (e and e - 1) or #json)

        local slot = tonumber(part:match('^{"id":(%-?%d+)'))
        if slot then
            local labels = part:match('"labels":%[(.*)$') or ''
            -- ID машины в игре лежит в labels числом без кавычек: {"title":575,"icon":"icon-id"}
            local vehid = labels:match('"title":(%d+),"icon":"icon%-id"') or labels:match('"title":(%d+)')
            cars[slot] = {
                slot    = slot,
                title   = part:match('"title":"(.-)"') or ('Слот '..slot),
                status  = part:match('"status":"(.-)"'),
                sysName = part:match('"sysName":"(.-)"'),
                vehid   = tonumber(vehid),
                plate   = labels:match('"title":"(.-)","icon":"icon%-car%-number"'),
            }
            count = count + 1
        end

        if not e then break end
        pos = s + 6
    end
    if count > 0 then
        rebuildCarsList()
        carsDirty = true
    end
    return count
end

local function handleCefJs(js)
    if cefDebug then
        sampAddChatMessage(tag..'{cccccc}'..js:sub(1, 220), -1)
    end
    local ev = js:match("executeEvent%('event%.([^']+)'")
    if not ev or not ev:find('vehicleMenu', 1, true) then return end
    local args = js:match('`(.*)`')
    if not args then return end

    if ev:find('pushVehicleItem', 1, true) then
        pushVehicleItems(args)
    elseif ev:find('setVehicleMaxSlot', 1, true) then
        maxSlots = tonumber(args:match('%d+')) or maxSlots
    elseif ev:find('setVehicleUsedSlot', 1, true) then
        usedSlots = tonumber(args:match('%d+')) or usedSlots
    end
end

local function handleCefEvent(name)
    if cefDebug then
        sampAddChatMessage(tag..'{cccccc}event: '..name, -1)
    end
    if name == 'vehicleMenu.loadList' then
        -- меню запросило список заново - чистим, чтобы проданные тачки не висели
        cars = {}
        carsList = {}
        carsDirty = true
    end
end

local function processCefPacket(id, bs)
    if id ~= CEF_PACKET then return end
    local saved = raknetBitStreamGetReadOffset(bs)
    pcall(function()
        local base = 0
        raknetBitStreamSetReadOffset(bs, 0)
        if raknetBitStreamReadInt8(bs) == CEF_PACKET then base = 8 end
        raknetBitStreamSetReadOffset(bs, base)
        local sub = raknetBitStreamReadInt8(bs)
        if sub == CEF_EXECUTE_JS then
            local js = cefDecodeJs(bs, base)
            if js then handleCefJs(js) end
        elseif sub == CEF_EVENT then
            local len = raknetBitStreamReadInt16(bs)
            if len and len > 0 and len < 512 then
                local name = raknetBitStreamReadString(bs, len)
                if name then handleCefEvent(name) end
            end
        end
    end)
    raknetBitStreamSetReadOffset(bs, saved)
end

function onReceivePacket(id, bs)
    processCefPacket(id, bs)
end

function onSendPacket(id, bs)
    processCefPacket(id, bs)
end

--==[TEXTDRAW CAR PREVIEW]==--
local td_Id = 1931
local winPos = {x = 1000, y = 1000}
local winSize = {x = 500, y = 200}

--==[ARIZONA]==--
function arizonaGetServerNumber()
    local send = 999
    local ip, port = sampGetCurrentServerAddress()
    local servers = {
        {'Chandler',    '185.169.134.44',   'chandler.arizona-rp.com'},
        {'Tucson',      '185.169.134.4',    'tucson.arizona-rp.com'},
        {'Space',       '80.66.82.199',     'space.arizona-rp.com'},
        {'Yuma',        '185.169.134.107',  'yuma.arizona-rp.com'},
        {'Casa-Grande', '80.66.82.188',     'casagrande.arizona-rp.com'},
        {'Bumble Bee',  '80.66.82.87',      'bumblebee.arizona-rp.com'},
        {'Love',        '80.66.82.33',      'love.arizona-rp.com'},
        {'Phoenix',     '185.169.134.3',    'phoenix.arizona-rp.com'},
        {'Drake',       '80.66.82.22',      'drake.arizona-rp.com'},
        {'Mesa',        '185.169.134.59',   'mesa.arizona-rp.com'},
        {'Red-Rock',    '185.169.134.61',   'redrock.arizona-rp.com'},
        {'Scottdale',   '185.169.134.43',   'scottdale.arizona-rp.com'},
        {'Brainburg',   '185.169.134.45',   'brainburg.arizona-rp.com'},
        {'Mirage',      '80.66.82.39',      'mirage.arizona-rp.com'},
        {'Saint-Rose',  '185.169.134.5',    'saintrose.arizona-rp.com'},
        {'Sedona',      '80.66.82.144',     'sedona.arizona-rp.com'},
        {'Sun-City',    '80.66.82.159',     'suncity.arizona-rp.com'},
        {'Winslow',     '185.169.134.173',  'winslow.arizona-rp.com'},
        {'Payson',      '185.169.134.174',  'payson.arizona-rp.com'},
        {'Kingman',     '185.169.134.172',  'kingman.arizona-rp.com'},
        {'Surprise',    '185.169.134.109',  'surprise.arizona-rp.com'},
        {'Prescott',    '185.169.134.166',  'prescott.arizona-rp.com'},
        {'Faraway',     '80.66.82.82',      'faraway.arizona-rp.com'},
        {'Glendale',    '185.169.134.171',  'glendale.arizona-rp.com'},
        {'Gilbert',     '80.66.82.191',     'gilbert.arizona-rp.com'},
        {'Show Low',    '80.66.82.190',     'showlow.arizona-rp.com'},
        {'Holiday',     '80.66.82.132',     'holiday.arizona-rp.com'},
        {'Queen-Creek', '80.66.82.200',     'queencreek.arizona-rp.com'},
        {'Wednesday',   '80.66.82.128',     'wednesday.arizona-rp.com'},
        {'Yava',        '80.66.82.113',     'yava.arizona-rp.com'},
        {'Page',        '80.66.82.168',     'page.arizona-rp.com'},
        {'Christmas',   '80.66.82.54',      'christmas.arizona-rp.com'},
    }
    -- сравнение строгое: find() путал 185.169.134.4 и 185.169.134.44
    for i = 1, #servers do
        if servers[i][2] == ip or servers[i][3] == ip then
            send = i
            break
        end
    end
    return send
end

function isArizonaLauncher()
    if doesFileExist(getGameDirectory()..'\\_CoreGame.asi') or doesFileExist(getGameDirectory()..'\\_ci.asi') then
        return true
    else
        return false
    end
end

-- 400-611 - стандартные модели GTA SA, всё остальное добавлено лаунчером Arizona
function isArizonaCar(modelId)
    local id = tonumber(modelId)
    if not id then return false end
    return id < 400 or id > 611
end

function main()
    while not isSampAvailable() do wait(200) end
    sampAddChatMessage(tag..'загружен! Автор: {698cc7}chapo{ffffff}. Активация: {698cc7}/vcar', -1)
    while not isCharOnFoot(PLAYER_PED) do wait(0) end
    if arizonaGetServerNumber() == 999 then
        sampAddChatMessage(tag..'скрипт предназначен только для Arizona RP! Если это ошибка - сообщите автору скрипта: {698cc7}vk.com/amid24', -1)
        thisScript():unload()
    end
    sampTextdrawCreate(td_Id, _, 1000, 1000)
    sampTextdrawSetStyle(td_Id, 5)
    sampTextdrawSetBoxColorAndSize(td_Id, 0, 0xFFff004d, 100, 100)
    sampTextdrawSetModelRotationZoomVehColor(td_Id, 411, 340, 0, 340, 1, 1, 1)
    sampTextdrawSetShadow(td_Id, _, 0x00)

    ensureCfgDir()
    loadReplaces()
    loadCars()
    if #carsList == 0 then
        sampAddChatMessage(tag..'список транспорта пуст. Открой {698cc7}/cars{ffffff} один раз - он подхватится сам.', -1)
    end

    sampRegisterChatCommand('vcar', function()
        window.v = not window.v
    end)
    sampRegisterChatCommand('vcarcef', function()
        cefDebug = not cefDebug
        sampAddChatMessage(tag..'отладка CEF: '..(cefDebug and '{55ff55}вкл' or '{ff5555}выкл'), -1)
    end)

    imgui.Process = false
    window.v = false

    local saveTimer = os.clock()
    while true do
        wait(0)
        imgui.Process = window.v
        if window.v then
            local tx, ty = convertWindowScreenCoordsToGameScreenCoords(winPos.x + winSize.x - 50, winPos.y - 20)
            sampTextdrawSetPos(td_Id, tx, ty)
        else
            sampTextdrawSetPos(td_Id, 1000, 1000)
        end
        -- список пишем на диск не чаще раза в 2 секунды
        if carsDirty and os.clock() - saveTimer > 2 then
            carsDirty = false
            saveTimer = os.clock()
            saveCars()
        end
    end
end

local selected = nil   -- слот выбранной машины
local new_selected = 0
local search = imgui.ImBuffer(256)

local function statusText(c)
    if c.vehid then
        return 'ID '..c.vehid..(c.plate and (' | '..c.plate) or '')
    elseif c.status == 'notLoaded' then
        return 'не загружена'
    elseif c.status then
        return c.status
    end
    return 'нет данных'
end

local function applyReplace(slot, idx)
    replaces[slot] = {
        title = cars[slot] and cars[slot].title or nil,
        name  = vehs[idx][1],
        model = vehs[idx][2],
    }
    saveReplaces()
end

function imgui.OnDrawFrame()
    if not window.v then return end

    local resX, resY = getScreenResolution()
    local sizeX, sizeY = 560, 260
    imgui.SetNextWindowPos(imgui.ImVec2(resX / 2 - sizeX / 2, resY / 2 - sizeY / 2), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSize(imgui.ImVec2(sizeX, sizeY), imgui.Cond.FirstUseEver)
    imgui.Begin('Visual Car Changer by chapo', window)

    local winPoss = imgui.GetWindowPos()
    winPos.x, winPos.y = winPoss.x, winPoss.y
    local winSizee = imgui.GetWindowSize()
    winSize.x, winSize.y = winSizee.x, winSizee.y

    imgui.Text(u8('Мой транспорт: '..#carsList..(maxSlots > 0 and (' (занято '..usedSlots..'/'..maxSlots..')') or '')))
    imgui.BeginChild('cars', imgui.ImVec2(300, winSize.y - 80), true)
        if #carsList == 0 then
            imgui.TextWrapped(u8'Список пуст.\nОткрой /cars - меню отдаст список само.')
        end
        for i, c in ipairs(carsList) do
            local r = replaces[c.slot]
            local label = c.title..' >> '..(r and r.name or 'нет замены')
            if imgui.Selectable(u8(label..'##slot'..c.slot), selected == c.slot) then
                selected = c.slot
            end
            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                imgui.Text(u8('Слот '..c.slot..' | '..statusText(c)))
                if r and r.title and r.title ~= c.title then
                    imgui.Text(u8('Замена привязана к: '..r.title..' (слот сместился?)'))
                end
                imgui.EndTooltip()
            end
        end
    imgui.EndChild()

    if imgui.Button(u8'Обновить (/cars)', imgui.ImVec2(145, 20)) then
        sampSendChat('/cars')
    end
    imgui.SameLine()
    if imgui.Button(u8'Убрать замену', imgui.ImVec2(145, 20)) then
        if selected then
            replaces[selected] = nil
            saveReplaces()
        end
    end

    imgui.SameLine()
    imgui.SetCursorPosY(45)
    imgui.BeginChild('changeto', imgui.ImVec2(winSize.x - 325, winSize.y - 55), true)
    if not selected or not cars[selected] then
        imgui.TextWrapped(u8'Выбери машину слева.\nЕсли список пуст - открой /cars.')
    else
        local c = cars[selected]
        imgui.Text(u8(c.title))
        imgui.TextDisabled(u8(statusText(c)))
        if not c.vehid then
            imgui.TextWrapped(u8'Машина не в мире - замена включится, когда она заспавнится.')
        end
        imgui.Separator()
        imgui.Text(u8'Поиск: ')
        imgui.SameLine()
        imgui.PushItemWidth(-1)
        imgui.InputText('##search', search)
        imgui.PopItemWidth()
        imgui.Separator()
        local filter = search.v:lower()
        for i = 1, #vehs do
            if filter == '' or vehs[i][1]:lower():find(filter, 1, true) then
                if imgui.Selectable(u8(vehs[i][1]..'##veh'..i), new_selected == i) then
                    new_selected = i
                    applyReplace(selected, i)
                end
                if imgui.IsItemHovered() then
                    local model = sampTextdrawGetModelRotationZoomVehColor(td_Id)
                    if model ~= vehs[i][2] then
                        sampTextdrawSetModelRotationZoomVehColor(td_Id, vehs[i][2], 340, 0, 340, 1, 1, 1)
                    end
                end
            end
        end
    end
    imgui.EndChild()
    imgui.End()
end

function sampev.onVehicleStreamIn(vehId, data)
    for slot, r in pairs(replaces) do
        local c = cars[slot]
        if c and c.vehid and c.vehid == vehId then
            if not isArizonaLauncher() and isArizonaCar(r.model) then
                sampAddChatMessage(tag..'модель машины не была заменена! (модель доступна только с лаунчера Arizona RP)', -1)
            else
                data.type = r.model
                return {vehId, data}
            end
        end
    end
end

-- запасной вариант: старое диалоговое меню /cars (если сервер отдаёт список диалогом)
function sampev.onShowDialog(id, style, title, button1, button2, text)
    if not title:find('Мой транспорт') then return end
    local list = {}
    for v in string.gmatch(text, '[^\n]+') do
        local name, vid
        if v:find('{FFD848}%[Twin Turbo%]{FFFFFF} (.+)%((%d+)%)') then
            name, vid = v:match('{FFD848}%[Twin Turbo%]{FFFFFF} (.+)%((%d+)%)')
        elseif v:find('{FF6347}%[Не припарковано%]{FFFFFF} (.+)%((%d+)%)') then
            name, vid = v:match('{FF6347}%[Не припарковано%]{FFFFFF} (.+)%((%d+)%)')
        elseif v:find('  (.+)%((%d+)%)') then
            name, vid = v:match('  (.+)%((%d+)%)')
        end
        if name and vid then
            list[#list + 1] = {name = name, vehid = tonumber(vid)}
        end
    end
    if #list == 0 then return end
    cars = {}
    for i, v in ipairs(list) do
        local slot = i - 1
        cars[slot] = {slot = slot, title = v.name, vehid = v.vehid, status = 'loaded'}
    end
    rebuildCarsList()
    carsDirty = true
end

function BH_theme()
    imgui.SwitchContext()
    local style = imgui.GetStyle()
    local colors = style.Colors
    local clr = imgui.Col
    local ImVec4 = imgui.ImVec4
    local ImVec2 = imgui.ImVec2

    style.WindowPadding = ImVec2(6, 4)
    style.WindowRounding = 5.0
    style.ChildWindowRounding = 5.0
    style.FramePadding = ImVec2(5, 2)
    style.FrameRounding = 5.0
    style.ItemSpacing = ImVec2(7, 5)
    style.ItemInnerSpacing = ImVec2(1, 1)
    style.TouchExtraPadding = ImVec2(0, 0)
    style.IndentSpacing = 6.0
    style.ScrollbarSize = 12.0
    style.ScrollbarRounding = 5.0
    style.GrabMinSize = 20.0
    style.GrabRounding = 2.0
    style.WindowTitleAlign = ImVec2(0.5, 0.5)

    colors[clr.Text]                   = ImVec4(1.00, 1.00, 1.00, 1.00)
    colors[clr.TextDisabled]           = ImVec4(0.28, 0.30, 0.35, 1.00)
    colors[clr.WindowBg]               = ImVec4(0.16, 0.18, 0.22, 1.00)
    colors[clr.ChildWindowBg]          = ImVec4(0.19, 0.22, 0.26, 1)
    colors[clr.PopupBg]                = ImVec4(0.05, 0.05, 0.10, 0.90)
    colors[clr.Border]                 = ImVec4(0.19, 0.22, 0.26, 1.00)
    colors[clr.BorderShadow]           = ImVec4(0.00, 0.00, 0.00, 0.00)
    colors[clr.FrameBg]                = ImVec4(0.16, 0.18, 0.22, 1.00)
    colors[clr.FrameBgHovered]         = ImVec4(0.22, 0.25, 0.30, 1.00)
    colors[clr.FrameBgActive]          = ImVec4(0.22, 0.25, 0.29, 1.00)
    colors[clr.TitleBg]                = ImVec4(0.19, 0.22, 0.26, 1.00)
    colors[clr.TitleBgActive]          = ImVec4(0.19, 0.22, 0.26, 1.00)
    colors[clr.TitleBgCollapsed]       = ImVec4(0.19, 0.22, 0.26, 0.59)
    colors[clr.MenuBarBg]              = ImVec4(0.19, 0.22, 0.26, 1.00)
    colors[clr.ScrollbarBg]            = ImVec4(0.20, 0.25, 0.30, 0.60)
    colors[clr.ScrollbarGrab]          = ImVec4(0.41, 0.55, 0.78, 1.00)
    colors[clr.ScrollbarGrabHovered]   = ImVec4(0.49, 0.63, 0.86, 1.00)
    colors[clr.ScrollbarGrabActive]    = ImVec4(0.49, 0.63, 0.86, 1.00)
    colors[clr.ComboBg]                = ImVec4(0.20, 0.20, 0.20, 0.99)
    colors[clr.CheckMark]              = ImVec4(0.90, 0.90, 0.90, 0.50)
    colors[clr.SliderGrab]             = ImVec4(1.00, 1.00, 1.00, 0.30)
    colors[clr.SliderGrabActive]       = ImVec4(0.80, 0.50, 0.50, 1.00)
    colors[clr.Button]                 = ImVec4(0.41, 0.55, 0.78, 1.00)
    colors[clr.ButtonHovered]          = ImVec4(0.49, 0.62, 0.85, 1.00)
    colors[clr.ButtonActive]           = ImVec4(0.49, 0.62, 0.85, 1.00)
    colors[clr.Header]                 = ImVec4(0.41, 0.55, 0.78, 1.00)
    colors[clr.HeaderHovered]          = ImVec4(0.43, 0.57, 0.80, 1.00)
    colors[clr.HeaderActive]           = ImVec4(0.43, 0.57, 0.80, 1.00)
    colors[clr.Separator]              = ImVec4(0.41, 0.55, 0.78, 1.00)
    colors[clr.SeparatorHovered]       = ImVec4(0.41, 0.55, 0.78, 1.00)
    colors[clr.SeparatorActive]        = ImVec4(0.41, 0.55, 0.78, 1.00)
    colors[clr.ResizeGrip]             = ImVec4(0.41, 0.55, 0.78, 1.00)
    colors[clr.ResizeGripHovered]      = ImVec4(0.49, 0.61, 0.83, 1.00)
    colors[clr.ResizeGripActive]       = ImVec4(0.49, 0.62, 0.83, 1.00)
    colors[clr.CloseButton]            = ImVec4(0.41, 0.55, 0.78, 1.00)
    colors[clr.CloseButtonHovered]     = ImVec4(0.50, 0.63, 0.84, 1.00)
    colors[clr.CloseButtonActive]      = ImVec4(0.41, 0.55, 0.78, 1.00)
    colors[clr.PlotLines]              = ImVec4(1.00, 1.00, 1.00, 1.00)
    colors[clr.PlotLinesHovered]       = ImVec4(0.90, 0.70, 0.00, 1.00)
    colors[clr.PlotHistogram]          = ImVec4(0.90, 0.70, 0.00, 1.00)
    colors[clr.PlotHistogramHovered]   = ImVec4(1.00, 0.60, 0.00, 1.00)
    colors[clr.TextSelectedBg]         = ImVec4(0.41, 0.55, 0.78, 1.00)
    colors[clr.ModalWindowDarkening]   = ImVec4(0.16, 0.18, 0.22, 0.76)
end
BH_theme()

function onScriptTerminate(s, q)
    if s == thisScript() then
        if sampTextdrawIsExists(td_Id) then
            sampTextdrawDelete(td_Id)
        end
    end
end
