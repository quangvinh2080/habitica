derby = require('derby')
{get, view, ready} = derby.createApp module
derby.use require('derby-ui-boot')
derby.use(require('../../ui'))

# Custom requires
content = require('./content')
scoring = require('./scoring')
schema = require('./schema')
helpers = require('./helpers')
helpers.viewHelpers(view)
# $ = require('jQuery')
# _ = require('underscore')

# ========== ROUTES ==========

get '/:uidParam?', (page, model, {uidParam}) ->
  
  # The session middleware will assign a _userId automatically
  userId = model.get '_userId'
  
  model.subscribe "users.#{userId}", (err, user) ->
    
    # Create new user if none exists
    unless user.get('id')
      # deep clone, else further new users get duplicate objects
      newUser = require('node.extend')(true, {}, schema.userSchema)
      for task in content.defaultTasks
        guid = task.id = require('derby/node_modules/racer').uuid()
        newUser.tasks[guid] = task
        switch task.type
          when 'habit' then newUser.habitIds.push guid 
          when 'daily' then newUser.dailyIds.push guid 
          when 'todo' then newUser.todoIds.push guid 
          when 'reward' then newUser.rewardIds.push guid 
      model.set "users.#{userId}", newUser
    # /end create new user
  
    model.ref '_user', user
    
    # Store
    model.set '_items'
      armor: content.items.armor[parseInt(user.get('items.armor')) + 1]
      weapon: content.items.weapon[parseInt(user.get('items.weapon')) + 1]
      potion: content.items.potion
      reroll: content.items.reroll

    # http://tibia.wikia.com/wiki/Formula 
    model.fn '_user._tnl', '_user.stats.lvl', (lvl) -> 50 * Math.pow(lvl, 2) - 150 * lvl + 200
    
    # Default Tasks
    model.refList "_habitList", "_user.tasks", "_user.habitIds"
    model.refList "_dailyList", "_user.tasks", "_user.dailyIds"
    model.refList "_todoList", "_user.tasks", "_user.todoIds"
    model.refList "_completedList", "_user.tasks", "_user.completedIds"
    model.refList "_rewardList", "_user.tasks", "_user.rewardIds"
    
    page.render()  

# ========== CONTROLLER FUNCTIONS ==========

ready (model) ->
  
  model.set '_purl', window.location.origin + '/' + model.get('_userId')
  
  $('[rel=popover]').popover()
  #TODO: this isn't very efficient, do model.on set for specific attrs for popover 
  model.on 'set', '*', ->
    $('[rel=popover]').popover()
  
  unless (model.get('_mobileDevice') == true) #don't do sortable on mobile
    # Make the lists draggable using jQuery UI
    # Note, have to setup helper function here and call it for each type later
    # due to variable binding of "type"
    setupSortable = (type) ->
      $("ul.#{type}s").sortable
        dropOnEmpty: false
        cursor: "move"
        items: "li"
        opacity: 0.4
        scroll: true
        axis: 'y'
        update: (e, ui) ->
          item = ui.item[0]
          domId = item.id
          id = item.getAttribute 'data-id'
          to = $("ul.#{type}s").children().index(item)
          # Use the Derby ignore option to suppress the normal move event
          # binding, since jQuery UI will move the element in the DOM.
          # Also, note that refList index arguments can either be an index
          # or the item's id property
          model.at("_#{type}List").pass(ignore: domId).move {id}, to
    setupSortable(type) for type in ['habit', 'daily', 'todo', 'reward']
  
  tour = new Tour()
  for step in content.tourSteps
    tour.addStep
      element: step.element
      title: step.title
      content: step.content
      placement: step.placement
  tour.start()
        
  model.on 'set', '_user.tasks.*.completed', (i, completed, previous, isLocal, passed) ->
    return if passed? && passed.cron # Don't do this stuff on cron
    direction = () ->
      return 'up' if completed==true and previous == false
      return 'down' if completed==false and previous == true
      throw new Error("Direction neither 'up' nor 'down' on checkbox set.")
      
    # Score the user based on todo task
    task = model.at("_user.tasks.#{i}")
    scoring.score({user:model.at('_user'), task:task, direction:direction()})
    
    # Then move the todos to/from _todoList/_completedList
    if task.get('type') == 'todo'
      [from, to] = if (direction()=='up') then ['todo', 'completed'] else ['completed', 'todo']
      [from, to] = ["_user.#{from}Ids", "_user.#{to}Ids"]
      # Remove from source (just remove the id from id-list)
      fromIds = model.get(from)
      fromIds.splice(fromIds.indexOf(i), 1)
      model.set from, fromIds
      # Push to target (just the id to id-list)
      toIds = model.get(to)
      toIds.push i
      model.set to, toIds
    
  exports.addTask = (e, el, next) ->
    type = $(el).attr('data-task-type')
    list = model.at "_#{type}List"
    newModel = model.at('_new' + type.charAt(0).toUpperCase() + type.slice(1))
    # Don't add a blank todo
    return unless text = view.escapeHtml newModel.get()
    newModel.set ''
    switch type

      when 'habit'
        list.push {type: type, text: text, notes: '', value: 0, up: true, down: true}

      when 'reward'
        list.push {type: type, text: text, notes: '', value: 20 }

      when 'daily', 'todo'
        list.push {type: type, text: text, notes: '', value: 0, completed: false }

        # list.on 'set', '*.completed', (i, completed, previous, isLocal) ->
          # # Move the item to the bottom if it was checked off
          # list.move i, -1  if completed && isLocal

  exports.del = (e, el) ->
    # Derby extends model.at to support creation from DOM nodes
    task = model.at(e.target)
    #TODO bug where I have to delete from _users.tasks AND _{type}List, 
    # fix when query subscriptions implemented properly
    model.del('_user.tasks.'+task.get('id'))
    task.remove()
    
  exports.clearCompleted = (e, el) ->
    _.each model.get('_completedList'), (task) ->
      model.del('_user.tasks.'+task.id)
      model.set('_user.completedIds', [])
    
  exports.toggleTaskEdit = (e, el) ->
    hideId = $(el).attr('data-hide-id')
    toggleId = $(el).attr('data-toggle-id')
    $(document.getElementById(hideId)).hide()
    $(document.getElementById(toggleId)).toggle()

  exports.toggleChart = (e, el) ->
    hideSelector = $(el).attr('data-hide-id')
    chartSelector = $(el).attr('data-toggle-id')
    historyPath = $(el).attr('data-history-path')
    $(document.getElementById(hideSelector)).hide()
    $(document.getElementById(chartSelector)).toggle()
    
    matrix = [['Date', 'Score']]
    for obj in model.get(historyPath)
      date = new Date(obj.date)
      readableDate = date.toISOString() #use toDateString() when done debugging
      matrix.push [ readableDate, obj.value ]
    data = google.visualization.arrayToDataTable matrix
    
    options = {
      title: 'History'
      #TODO use current background color: $(el).css('background-color), but convert to hex (see http://goo.gl/ql5pR)
      backgroundColor: 'whiteSmoke'
    }

    chart = new google.visualization.LineChart(document.getElementById( chartSelector ))
    chart.draw(data, options)
    
  exports.buyItem = (e, el, next) ->
    user = model.at '_user'
    #TODO: this should be working but it's not. so instead, i'm passing all needed values as data-attrs
    # item = model.at(e.target)
    
    money = user.get 'stats.money'
    [type, value, index] = [ $(el).attr('data-type'), $(el).attr('data-value'), $(el).attr('data-index') ]
    
    return if money < value
    user.set 'stats.money', money - value
    if type == 'armor'
      user.set 'items.armor', index
      model.set '_items.armor', content.items.armor[parseInt(index) + 1]
    else if type == 'weapon'
      user.set 'items.weapon', index
      model.set '_items.weapon', content.items.weapon[parseInt(index) + 1]
    else if type == 'potion'
      hp = user.get 'stats.hp'
      hp += 15
      hp = 50 if hp > 50 
      user.set 'stats.hp', hp
    else if type == 'reroll'
      for taskId of user.get('tasks')
        task = model.at('_user.tasks.'+taskId)
        task.set('value', 0) unless task.get('type')=='reward' 
        
      
  exports.vote = (e, el, next) ->
    direction = $(el).attr('data-direction')
    direction = 'up' if direction == 'true/'
    direction = 'down' if direction == 'false/'
    user = model.at('_user')
    task = model.at $(el).parents('li')[0]
    
    scoring.score({user:user, task:task, direction:direction}) 
    
  exports.revive = (e, el) ->
    stats = model.at '_user.stats'
    stats.set 'hp', 50; stats.set 'lvl', 1; stats.set 'exp', 0; stats.set 'money', 0
    model.set '_user.items.armor', 0
    model.set '_user.items.weapon', 0
    model.set '_items.armor', content.items.armor[1]
    model.set '_items.weapon', content.items.weapon[1]
    
  # ========== CRON ==========
  
  #TODO: remove when cron implemented 
  exports.poormanscron = poormanscron = ->
    today = new Date()
    model.setNull('_user.lastCron', today)
    lastCron = model.get('_user.lastCron')
    daysPassed = helpers.daysBetween(lastCron, today)
    if daysPassed > 0
      model.set('_user.lastCron', today) # reset cron
      for n in [1..daysPassed]
        scoring.tally(model)
  poormanscron() # Run once on refresh
  setInterval (-> # Then run once every hour
    poormanscron()
  ), 3600000
  
  # ========== DEBUGGING ==========
  
  exports.endOfDayTally = (e, el) ->
    scoring.tally(model)
  
  # Temporary solution to running updates against the schema when the code changes
  exports.updateSchema = (e, el) ->
    schema.updateSchema(model)
    
  # ========== SHORTCUTS ==========

  exports.shortcuts = (e) ->
    return unless e.metaKey || e.ctrlKey
    code = e.which
    return unless command = (switch code
      when 66 then 'bold'           # Bold: Ctrl/Cmd + B
      when 73 then 'italic'         # Italic: Ctrl/Cmd + I
      when 32 then 'removeFormat'   # Clear formatting: Ctrl/Cmd + Space
      when 220 then 'removeFormat'  # Clear formatting: Ctrl/Cmd + \
      else null
    )
    document.execCommand command, false, null
    e.preventDefault() if e.preventDefault
    return false

  # Tell Firefox to use elements for styles instead of CSS
  # See: https://developer.mozilla.org/en/Rich-Text_Editing_in_Mozilla
  document.execCommand 'useCSS', false, true
  document.execCommand 'styleWithCSS', false, false
